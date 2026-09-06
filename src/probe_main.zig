const std = @import("std");
const probe_env = @import("probe_env.zig");
const h2 = @import("h2.zig");
const proto = @import("proto.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var endpoint = try probe_env.load(allocator);
    defer endpoint.deinit();

    const host_bytes = try proto.encodeHost(allocator, .{ .arch = "aarch64", .version = "0.20.5-zig-probe" });
    defer allocator.free(host_bytes);

    {
        var client = try h2.Client.connect(allocator, endpoint.authority, endpoint.host, endpoint.port, endpoint.secret);
        defer client.deinit();
        const info_reply = try client.unary("/proto.NezhaService/ReportSystemInfo", host_bytes);
        defer allocator.free(info_reply);
        const info_receipt = try proto.decodeReceipt(info_reply);
        std.debug.print("ReportSystemInfo proced={}\n", .{info_receipt.proced});

        const state_bytes = try proto.encodeState(allocator, .{});
        defer allocator.free(state_bytes);
        const state_reply = try client.unary("/proto.NezhaService/ReportSystemState", state_bytes);
        defer allocator.free(state_reply);
        const state_receipt = try proto.decodeReceipt(state_reply);
        std.debug.print("ReportSystemState proced={}\n", .{state_receipt.proced});
    }

    // Use a separate connection for the long-lived task stream, matching the
    // production agent's one-connection-per-operation design.
    var task_client = try h2.Client.connect(allocator, endpoint.authority, endpoint.host, endpoint.port, endpoint.secret);
    defer task_client.deinit();
    var tasks = try task_client.openTaskStream(host_bytes);
    defer tasks.deinit();
    if (try tasks.next()) |task| {
        std.debug.print("Task id={} type={} data={s}\n", .{ task.id, task.type, task.data });
    } else {
        std.debug.print("No task before stream end\n", .{});
    }
}
