//! Nezha v0.20.5: independent state reporting, bounded ICMP work and result queues.
const std = @import("std");
const builtin = @import("builtin");
const h2 = @import("h2.zig");
const icmp = @import("icmp.zig");
const monitor_mod = @import("monitor.zig");
const proto = @import("proto.zig");
const config_mod = @import("config.zig");
const Queue = @import("bounded_queue.zig").Queue;

comptime {
    if (builtin.os.tag != .linux) @compileError("the agent is Linux-only; use protocol_probe.zig on other hosts");
}

const worker_stack_size = 256 * 1024;
const TaskJob = struct {
    id: u64,
    typ: u64,
    data: [256]u8 = undefined,
    len: usize,
    received: std.time.Instant,
};
const ResultJob = struct {
    // data is always a static error name/message, never a slice into a TaskJob.
    result: proto.TaskResult,
    created: std.time.Instant,
};
const Counter = std.atomic.Value(u64);
const Stats = struct {
    received: Counter = .init(0),
    completed: Counter = .init(0),
    rejected: Counter = .init(0),
    active: Counter = .init(0),
    peak_active: Counter = .init(0),
    reported: Counter = .init(0),
    report_errors: Counter = .init(0),
    dropped_results: Counter = .init(0),
    states: Counter = .init(0),
};
const App = struct {
    allocator: std.mem.Allocator,
    config: *const config_mod.Config,
    tasks: *Queue(TaskJob),
    results: *Queue(ResultJob),
    refresh_host: std.atomic.Value(bool) = .init(false),
    stopping: std.atomic.Value(bool) = .init(false),
    stats: Stats = .{},
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var config = config_mod.parse(allocator, args[1..]) catch |err| {
        usage();
        if (err == error.HelpRequested) return;
        return err;
    };
    defer config.deinit();
    if (config.once) {
        try reportOnce(allocator, &config);
        return;
    }

    var tasks = try Queue(TaskJob).init(allocator, config.queue_capacity);
    defer tasks.deinit();
    var results = try Queue(ResultJob).init(allocator, @max(128, config.queue_capacity * 2));
    defer results.deinit();
    var app = App{ .allocator = allocator, .config = &config, .tasks = &tasks, .results = &results };
    var threads: [1 + config_mod.max_workers + config_mod.max_report_workers]std.Thread = undefined;
    var started: usize = 0;
    errdefer {
        app.stopping.store(true, .monotonic);
        tasks.close();
        results.close();
        for (threads[0..started]) |thread| thread.join();
    }
    for (0..config.workers) |_| {
        threads[started] = try std.Thread.spawn(.{ .stack_size = worker_stack_size }, taskWorker, .{&app});
        started += 1;
    }
    for (0..config.report_workers) |_| {
        threads[started] = try std.Thread.spawn(.{ .stack_size = worker_stack_size }, resultWorker, .{&app});
        started += 1;
    }
    threads[started] = try std.Thread.spawn(.{ .stack_size = worker_stack_size }, reportLoop, .{&app});
    started += 1;
    std.debug.print("nezha-agent-lite workers={d} report_workers={d} queue={d} report_delay={d}s task_max_age={d}s\n", .{
        config.workers, config.report_workers, config.queue_capacity, config.report_delay, config.task_max_age,
    });
    taskLoop(&app);
}

fn usage() void {
    std.debug.print(
        "usage: nezha-agent-lite -s host:port -p secret [--workers 1..64] [--report-workers 1..8]\n" ++
            "       [--queue-capacity 1..1024] [--report-delay 1..30] [--task-max-age 1..300]\n" ++
            "       [--rpc-timeout 1..60] [--debug] [--once]\n",
        .{},
    );
}

fn connect(allocator: std.mem.Allocator, config: *const config_mod.Config) !h2.Client {
    return h2.Client.connectWithTimeout(allocator, config.server.authority, config.server.host, config.server.port, config.secret, config.rpc_timeout_ms);
}

fn checkedCall(client: *h2.Client, allocator: std.mem.Allocator, path: []const u8, payload: []const u8) !void {
    const reply = try client.unary(path, payload);
    defer allocator.free(reply);
    try proto.requireReceipt(reply);
}

fn reportOnce(allocator: std.mem.Allocator, config: *const config_mod.Config) !void {
    var monitor = monitor_mod.Monitor.init(allocator);
    var client = try connect(allocator, config);
    defer client.deinit();
    const host = try proto.encodeHost(allocator, monitor.host());
    defer allocator.free(host);
    try checkedCall(&client, allocator, "/proto.NezhaService/ReportSystemInfo", host);
    const state = try proto.encodeState(allocator, monitor.state());
    defer allocator.free(state);
    try checkedCall(&client, allocator, "/proto.NezhaService/ReportSystemState", state);
    std.debug.print("host and state receipts accepted\n", .{});
}

fn closeClient(client: *?h2.Client) void {
    if (client.*) |*active| active.deinit();
    client.* = null;
}

fn reportLoop(app: *App) void {
    var monitor = monitor_mod.Monitor.init(app.allocator);
    var client: ?h2.Client = null;
    defer closeClient(&client);
    var host_needed = true;
    var host_timer = std.time.Timer.start() catch unreachable;
    var stats_timer = std.time.Timer.start() catch unreachable;
    while (!app.stopping.load(.monotonic)) {
        if (app.refresh_host.swap(false, .monotonic) or host_timer.read() >= 600 * std.time.ns_per_s) {
            monitor = monitor_mod.Monitor.init(app.allocator);
            host_needed = true;
            host_timer.reset();
        }
        reportCycle(app, &monitor, &client, &host_needed) catch |err| {
            logError("state report", err);
            closeClient(&client);
            host_needed = true;
        };
        if (stats_timer.read() >= 30 * std.time.ns_per_s) {
            logStats(app);
            stats_timer.reset();
        }
        std.Thread.sleep(app.config.report_delay * std.time.ns_per_s);
    }
}

fn reportCycle(app: *App, monitor: *monitor_mod.Monitor, client: *?h2.Client, host_needed: *bool) !void {
    if (client.* == null) client.* = try connect(app.allocator, app.config);
    const active = &client.*.?;
    if (host_needed.*) {
        const host = try proto.encodeHost(app.allocator, monitor.host());
        defer app.allocator.free(host);
        try checkedCall(active, app.allocator, "/proto.NezhaService/ReportSystemInfo", host);
        host_needed.* = false;
    }
    const state = try proto.encodeState(app.allocator, monitor.state());
    defer app.allocator.free(state);
    try checkedCall(active, app.allocator, "/proto.NezhaService/ReportSystemState", state);
    _ = app.stats.states.fetchAdd(1, .monotonic);
}

fn taskLoop(app: *App) noreturn {
    while (true) {
        receiveTasks(app) catch |err| logError("task stream", err);
        std.Thread.sleep(5 * std.time.ns_per_s);
    }
}

fn receiveTasks(app: *App) !void {
    var client = try connect(app.allocator, app.config);
    defer client.deinit();
    var monitor = monitor_mod.Monitor.init(app.allocator);
    const host = try proto.encodeHost(app.allocator, monitor.host());
    defer app.allocator.free(host);
    var stream = try client.openTaskStream(host);
    defer stream.deinit();
    while (try stream.next()) |task| try dispatchTask(app, task);
}

fn dispatchTask(app: *App, task: proto.Task) !void {
    // Control tasks must not wait behind probes or generate synthetic failures.
    if (task.type == 7) return; // v0.20.5 Keepalive
    if (task.type == 10) { // v0.20.5 ReportHostInfo
        app.refresh_host.store(true, .monotonic);
        return;
    }
    _ = app.stats.received.fetchAdd(1, .monotonic);
    if (task.type != 2) {
        rejectTask(app, task, "unsupported by nezha-agent-lite");
        return;
    }
    if (task.data.len == 0 or task.data.len > 256) {
        rejectTask(app, task, "invalid ICMP target length");
        return;
    }
    var job = TaskJob{ .id = task.id, .typ = task.type, .len = task.data.len, .received = try std.time.Instant.now() };
    @memcpy(job.data[0..job.len], task.data);
    if (!app.tasks.tryPush(job)) rejectTask(app, task, "ICMP queue full");
}

fn rejectTask(app: *App, task: proto.Task, message: []const u8) void {
    _ = app.stats.rejected.fetchAdd(1, .monotonic);
    std.debug.print("task id={d} rejected: {s}\n", .{ task.id, message });
    enqueueResult(app, .{ .id = task.id, .type = task.type, .data = message });
}

fn taskWorker(app: *App) void {
    while (app.tasks.pop()) |job| {
        if (app.stopping.load(.monotonic)) break;
        const active = app.stats.active.fetchAdd(1, .monotonic) + 1;
        _ = app.stats.peak_active.fetchMax(active, .monotonic);
        const result = executeTask(app, &job);
        _ = app.stats.active.fetchSub(1, .monotonic);
        _ = app.stats.completed.fetchAdd(1, .monotonic);
        enqueueResult(app, result);
    }
}

fn executeTask(app: *App, job: *const TaskJob) proto.TaskResult {
    var result = proto.TaskResult{ .id = job.id, .type = job.typ };
    const now = std.time.Instant.now() catch {
        result.data = "monotonic clock unavailable";
        return result;
    };
    const age_ns = now.since(job.received);
    const max_age_ns = app.config.task_max_age * std.time.ns_per_s;
    if (age_ns >= max_age_ns) {
        result.data = "ICMP task expired in queue";
        return result;
    }
    const timeout_ms: u32 = @intCast(@min(20000, (max_age_ns - age_ns) / std.time.ns_per_ms));
    const reply = icmp.pingWithTimeout(app.allocator, job.data[0..job.len], timeout_ms) catch |err| {
        result.data = @errorName(err);
        return result;
    };
    result.delay = reply.delay_ms;
    result.successful = reply.successful;
    result.data = reply.message;
    return result;
}

fn enqueueResult(app: *App, result: proto.TaskResult) void {
    const created = std.time.Instant.now() catch {
        _ = app.stats.dropped_results.fetchAdd(1, .monotonic);
        std.debug.print("task id={d}: result lost, monotonic clock unavailable\n", .{result.id});
        return;
    };
    if (!app.results.tryPush(.{ .result = result, .created = created })) {
        _ = app.stats.dropped_results.fetchAdd(1, .monotonic);
        std.debug.print("task id={d}: result queue full, result not reported\n", .{result.id});
    }
}

fn resultWorker(app: *App) void {
    var client: ?h2.Client = null;
    defer closeClient(&client);
    while (app.results.pop()) |job| {
        if (app.stopping.load(.monotonic)) break;
        var sent = false;
        for (0..2) |attempt| {
            const now = std.time.Instant.now() catch break;
            if (now.since(job.created) >= 60 * std.time.ns_per_s) break;
            sendResult(app, &client, job.result) catch |err| {
                _ = app.stats.report_errors.fetchAdd(1, .monotonic);
                std.debug.print("ReportTask id={d} attempt={d}: {s}\n", .{ job.result.id, attempt + 1, @errorName(err) });
                closeClient(&client);
                if (err == error.ServerRejected) break;
                if (attempt == 0) std.Thread.sleep(std.time.ns_per_s);
                continue;
            };
            sent = true;
            _ = app.stats.reported.fetchAdd(1, .monotonic);
            if (app.config.debug) std.debug.print("ReportTask id={d} successful={} delay_ms={d:.3} receipt=true\n", .{
                job.result.id, job.result.successful, job.result.delay,
            });
            break;
        }
        if (!sent) {
            _ = app.stats.dropped_results.fetchAdd(1, .monotonic);
            std.debug.print("ReportTask id={d}: not acknowledged within retry/age limit\n", .{job.result.id});
        }
    }
}

fn sendResult(app: *App, client: *?h2.Client, result: proto.TaskResult) !void {
    if (client.* == null) client.* = try connect(app.allocator, app.config);
    const payload = try proto.encodeTaskResult(app.allocator, result);
    defer app.allocator.free(payload);
    try checkedCall(&client.*.?, app.allocator, "/proto.NezhaService/ReportTask", payload);
}

fn logStats(app: *App) void {
    const tasks = app.tasks.snapshot();
    const results = app.results.snapshot();
    std.debug.print("stats states={d} tasks={d} completed={d} rejected={d} active={d} peak_active={d} task_queue={d}/{d} result_queue={d}/{d} reported={d} report_errors={d} dropped_results={d}\n", .{
        app.stats.states.load(.monotonic),          app.stats.received.load(.monotonic),
        app.stats.completed.load(.monotonic),       app.stats.rejected.load(.monotonic),
        app.stats.active.load(.monotonic),          app.stats.peak_active.load(.monotonic),
        tasks.pending,                              tasks.peak,
        results.pending,                            results.peak,
        app.stats.reported.load(.monotonic),        app.stats.report_errors.load(.monotonic),
        app.stats.dropped_results.load(.monotonic),
    });
}

fn logError(operation: []const u8, err: anyerror) void {
    std.debug.print("{s}: {s}\n", .{ operation, @errorName(err) });
}
