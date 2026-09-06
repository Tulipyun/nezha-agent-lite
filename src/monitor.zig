//! Linux-only, allocation-light host and state collection.
//!
//! The original agent uses gopsutil.  On a small OpenWrt image the required
//! subset is cheaper and more predictable when read directly from procfs,
//! sysfs, and statvfs.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("proto.zig");
const mounts = @import("mounts.zig");
const release_info = @import("release_info.zig");

comptime {
    if (builtin.os.tag != .linux) @compileError("monitor.zig is Linux-only");
}

const Allocator = std.mem.Allocator;
const MAX_PROC_FILE = 256 * 1024;
var scratch_mutex: std.Thread.Mutex = .{};
var scratch: [MAX_PROC_FILE]u8 = undefined;

const Statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: c_ulong,
    f_bfree: c_ulong,
    f_bavail: c_ulong,
    f_files: c_ulong,
    f_ffree: c_ulong,
    f_favail: c_ulong,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    f_spare: [6]c_int,
};

extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

pub const Monitor = struct {
    allocator: Allocator,
    platform_buf: [128]u8 = undefined,
    platform_len: usize = 0,
    platform_version_buf: [64]u8 = undefined,
    platform_version_len: usize = 0,
    cpu_buf: [192]u8 = undefined,
    cpu_len: usize = 0,
    cpu_models: [1][]const u8 = undefined,
    boot_time: u64 = 0,
    prev_cpu_total: u64 = 0,
    prev_cpu_idle: u64 = 0,
    cpu_ready: bool = false,
    prev_net_in: u64 = 0,
    prev_net_out: u64 = 0,
    prev_net_ms: i64 = 0,
    net_ready: bool = false,

    pub fn init(allocator: Allocator) Monitor {
        var m = Monitor{ .allocator = allocator };
        m.refreshStaticInfo();
        return m;
    }

    pub fn host(self: *Monitor) proto.Host {
        // init() returns the struct by value. Rebind this interior slice after
        // any move/copy instead of retaining a pointer to init's stack buffer.
        self.cpu_models[0] = self.cpu_buf[0..self.cpu_len];
        return .{
            .platform = self.platform_buf[0..self.platform_len],
            .platform_version = self.platform_version_buf[0..self.platform_version_len],
            .cpu = self.cpu_models[0..if (self.cpu_len > 0) 1 else 0],
            .mem_total = readMeminfo().mem_total,
            .disk_total = diskUsage().total,
            .swap_total = readMeminfo().swap_total,
            .arch = @tagName(builtin.cpu.arch),
            .boot_time = self.boot_time,
            .version = "0.20.5-zig",
        };
    }

    pub fn state(self: *Monitor) proto.State {
        const mem = readMeminfo();
        const cpu = self.readCpuPercent();
        const net = self.readNetwork();
        const disk = diskUsage();
        const load = readLoad();
        const uptime = readUptime();
        return .{
            .cpu = cpu,
            .mem_used = if (mem.mem_total > mem.mem_available) mem.mem_total - mem.mem_available else 0,
            .swap_used = if (mem.swap_total > mem.swap_free) mem.swap_total - mem.swap_free else 0,
            .disk_used = disk.used,
            .net_in_transfer = net.in_bytes,
            .net_out_transfer = net.out_bytes,
            .net_in_speed = net.in_speed,
            .net_out_speed = net.out_speed,
            .uptime = uptime,
            .load1 = load[0],
            .load5 = load[1],
            .load15 = load[2],
            .tcp_conn_count = countConnections("/proc/net/tcp") + countConnections("/proc/net/tcp6"),
            .udp_conn_count = countConnections("/proc/net/udp") + countConnections("/proc/net/udp6"),
            .process_count = countProcesses(),
        };
    }

    fn refreshStaticInfo(self: *Monitor) void {
        self.platform_len = copyTrimmed(&self.platform_buf, "Linux");
        // The dashboard renders architecture from Host.arch. Leave version
        // empty so SNAPSHOT/revision strings are not appended to the name.
        self.platform_version_len = 0;

        for ([_][]const u8{ "/etc/os-release", "/usr/lib/os-release" }) |path| {
            const release = readFile(path, self.allocator, 16 * 1024) catch continue;
            defer self.allocator.free(release);
            self.platform_len = copyTrimmed(&self.platform_buf, release_info.name("", release));
            break;
        }

        if (readFile("/etc/openwrt_release", self.allocator, 16 * 1024)) |release| {
            defer self.allocator.free(release);
            if (release_info.value(release, "DISTRIB_ID")) |name| {
                self.platform_len = copyTrimmed(&self.platform_buf, name);
            }
        } else |_| {}

        if (readFile("/proc/cpuinfo", self.allocator, 64 * 1024)) |cpuinfo| {
            defer self.allocator.free(cpuinfo);
            var lines = std.mem.splitScalar(u8, cpuinfo, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (self.cpu_len == 0 and (std.mem.startsWith(u8, trimmed, "model name") or
                    std.mem.startsWith(u8, trimmed, "Processor") or
                    std.mem.startsWith(u8, trimmed, "Hardware")))
                {
                    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                        self.cpu_len = copyTrimmed(&self.cpu_buf, trimmed[colon + 1 ..]);
                    }
                }
            }
            if (self.cpu_len == 0) self.cpu_len = copyTrimmed(&self.cpu_buf, "ARMv8");
        } else |_| {
            self.cpu_len = copyTrimmed(&self.cpu_buf, "ARMv8");
        }

        self.boot_time = readBootTime();
    }

    fn readCpuPercent(self: *Monitor) f64 {
        const cpu = readCpuCounters();
        if (!cpu.ok) return 0;
        if (!self.cpu_ready) {
            self.prev_cpu_total = cpu.total;
            self.prev_cpu_idle = cpu.idle;
            self.cpu_ready = true;
            return 0;
        }
        const total_delta = cpu.total -| self.prev_cpu_total;
        const idle_delta = cpu.idle -| self.prev_cpu_idle;
        self.prev_cpu_total = cpu.total;
        self.prev_cpu_idle = cpu.idle;
        if (total_delta == 0 or idle_delta > total_delta) return 0;
        return @as(f64, @floatFromInt(total_delta - idle_delta)) * 100.0 /
            @as(f64, @floatFromInt(total_delta));
    }

    const Network = struct {
        in_bytes: u64 = 0,
        out_bytes: u64 = 0,
        in_speed: u64 = 0,
        out_speed: u64 = 0,
    };

    fn readNetwork(self: *Monitor) Network {
        var result = Network{};
        const data = readFile("/proc/net/dev", self.allocator, 64 * 1024) catch return result;
        defer self.allocator.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = std.mem.trim(u8, line[0..colon], " \t");
            if (excludedInterface(name)) continue;
            var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
            const rx = fields.next() orelse continue;
            var i: usize = 0;
            while (i < 7) : (i += 1) _ = fields.next() orelse break;
            const tx = fields.next() orelse continue;
            result.in_bytes += std.fmt.parseInt(u64, rx, 10) catch 0;
            result.out_bytes += std.fmt.parseInt(u64, tx, 10) catch 0;
        }
        const now = std.time.milliTimestamp();
        if (self.net_ready) {
            const delta_ms = now - self.prev_net_ms;
            if (delta_ms > 0) {
                result.in_speed = ((result.in_bytes -| self.prev_net_in) * 1000) / @as(u64, @intCast(delta_ms));
                result.out_speed = ((result.out_bytes -| self.prev_net_out) * 1000) / @as(u64, @intCast(delta_ms));
            }
        } else {
            self.net_ready = true;
        }
        self.prev_net_in = result.in_bytes;
        self.prev_net_out = result.out_bytes;
        self.prev_net_ms = now;
        return result;
    }
};

const MemInfo = struct {
    mem_total: u64 = 0,
    mem_available: u64 = 0,
    swap_total: u64 = 0,
    swap_free: u64 = 0,
};

fn readMeminfo() MemInfo {
    var result = MemInfo{};
    scratch_mutex.lock();
    defer scratch_mutex.unlock();
    const data = readSmallFile("/proc/meminfo", scratch[0 .. 32 * 1024]) catch return result;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        var fields = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
        const value = fields.next() orelse continue;
        const parsed = std.fmt.parseInt(u64, value, 10) catch continue;
        const bytes = if (std.mem.eql(u8, fields.next() orelse "", "kB")) parsed * 1024 else parsed;
        if (std.mem.eql(u8, key, "MemTotal")) result.mem_total = bytes else if (std.mem.eql(u8, key, "MemAvailable")) result.mem_available = bytes else if (std.mem.eql(u8, key, "SwapTotal")) result.swap_total = bytes else if (std.mem.eql(u8, key, "SwapFree")) result.swap_free = bytes;
    }
    return result;
}

const CpuCounters = struct { total: u64 = 0, idle: u64 = 0, ok: bool = false };

fn readCpuCounters() CpuCounters {
    scratch_mutex.lock();
    defer scratch_mutex.unlock();
    const data = readSmallFile("/proc/stat", scratch[0 .. 16 * 1024]) catch return .{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    const line = lines.next() orelse return .{};
    var fields = std.mem.tokenizeAny(u8, line, " \t");
    if (!std.mem.eql(u8, fields.next() orelse "", "cpu")) return .{};
    var values: [8]u64 = undefined;
    var count: usize = 0;
    while (count < values.len) : (count += 1) {
        values[count] = std.fmt.parseInt(u64, fields.next() orelse return .{}, 10) catch return .{};
    }
    var total: u64 = 0;
    for (values) |v| total += v;
    return .{ .total = total, .idle = values[3] + values[4], .ok = true };
}

fn readLoad() [3]f64 {
    scratch_mutex.lock();
    defer scratch_mutex.unlock();
    const data = readSmallFile("/proc/loadavg", scratch[0..256]) catch return .{ 0, 0, 0 };
    var fields = std.mem.tokenizeAny(u8, data, " \t\r\n");
    return .{
        std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
        std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
        std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0,
    };
}

fn readUptime() u64 {
    scratch_mutex.lock();
    defer scratch_mutex.unlock();
    const data = readSmallFile("/proc/uptime", scratch[0..128]) catch return 0;
    var fields = std.mem.tokenizeAny(u8, data, " \t\r\n");
    const seconds = std.fmt.parseFloat(f64, fields.next() orelse "0") catch 0;
    return if (seconds <= 0) 0 else @intFromFloat(seconds);
}

fn readBootTime() u64 {
    scratch_mutex.lock();
    defer scratch_mutex.unlock();
    const data = readSmallFile("/proc/stat", scratch[0 .. 32 * 1024]) catch return 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "btime ")) return std.fmt.parseInt(u64, std.mem.trim(u8, line[6..], " \t"), 10) catch 0;
    }
    return 0;
}

const Disk = mounts.Usage;

fn diskUsage() Disk {
    scratch_mutex.lock();
    defer scratch_mutex.unlock();
    if (readSmallFile("/proc/self/mountinfo", &scratch)) |data| {
        const combined = mounts.collect(data, std.heap.page_allocator, {}, usageAt) catch Disk{};
        if (combined.total != 0 or combined.used != 0) return combined;
    } else |_| {}
    return usageAt({}, "/") orelse .{};
}

fn usageAt(_: void, path: [:0]const u8) ?Disk {
    var stats: Statvfs = undefined;
    if (statvfs(path.ptr, &stats) != 0) return null;
    const block_size: u64 = @intCast(if (stats.f_frsize != 0) stats.f_frsize else stats.f_bsize);
    const total = @as(u64, @intCast(stats.f_blocks)) * block_size;
    // Match gopsutil: reserved-but-free blocks are not used data.
    const free = @as(u64, @intCast(stats.f_bfree)) * block_size;
    return .{ .total = total, .used = total -| free };
}

fn countConnections(path: []const u8) u64 {
    scratch_mutex.lock();
    defer scratch_mutex.unlock();
    const data = readSmallFile(path, &scratch) catch return 0;
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    _ = lines.next(); // header
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len > 0) count += 1;
    }
    return count;
}

fn countProcesses() u64 {
    var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return 0;
    defer dir.close();
    var iterator = dir.iterate();
    var count: u64 = 0;
    while (iterator.next() catch null) |entry| {
        if (entry.kind != .directory or entry.name.len == 0) continue;
        var numeric = true;
        for (entry.name) |ch| {
            if (ch < '0' or ch > '9') numeric = false;
        }
        if (numeric) count += 1;
    }
    return count;
}

fn excludedInterface(name: []const u8) bool {
    if (std.mem.eql(u8, name, "lo")) return true;
    for ([_][]const u8{ "tun", "docker", "veth", "br-", "vmbr", "vnet", "kube" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) return true;
    }
    return false;
}

fn readFile(path: []const u8, allocator: Allocator, max_bytes: usize) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, max_bytes);
}

fn readSmallFile(path: []const u8, buffer: []u8) ![]u8 {
    var file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    var used: usize = 0;
    while (used < buffer.len) {
        const n = try file.read(buffer[used..]);
        if (n == 0) return buffer[0..used];
        used += n;
    }
    var probe: [1]u8 = undefined;
    if (try file.read(&probe) != 0) return error.FileTooLarge;
    return buffer;
}

fn copyTrimmed(dest: []u8, source: []const u8) usize {
    const trimmed = std.mem.trim(u8, source, " \t\r\n\"'");
    const len = @min(dest.len, trimmed.len);
    @memcpy(dest[0..len], trimmed[0..len]);
    return len;
}

test "proc parsers do not panic on local data" {
    if (builtin.os.tag != .linux) return;
    var monitor = Monitor.init(std.testing.allocator);
    _ = monitor.host();
    _ = monitor.state();
}
