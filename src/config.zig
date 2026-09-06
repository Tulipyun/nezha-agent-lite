const std = @import("std");

pub const max_workers = 64;
pub const max_report_workers = 8;
pub const max_queue_capacity = 1024;

pub const Server = struct {
    host: []u8,
    authority: []u8,
    port: u16,

    pub fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        allocator.free(self.host);
        allocator.free(self.authority);
    }
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    server: Server,
    secret: []const u8,
    report_delay: u64 = 1,
    workers: usize = 8,
    report_workers: usize = 2,
    queue_capacity: usize = 128,
    task_max_age: u64 = 30,
    rpc_timeout_ms: u32 = 5000,
    debug: bool = false,
    once: bool = false,

    pub fn deinit(self: *Config) void {
        self.server.deinit(self.allocator);
    }
};

/// Argument strings, including the secret, remain owned by the caller.
pub fn parse(allocator: std.mem.Allocator, args: []const []const u8) !Config {
    var server_text: ?[]const u8 = null;
    var secret: []const u8 = "";
    var report_delay: u64 = 1;
    var workers: usize = 8;
    var report_workers: usize = 2;
    var queue_capacity: usize = 128;
    var task_max_age: u64 = 30;
    var rpc_timeout: u32 = 5;
    var debug = false;
    var once = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--debug")) {
            debug = true;
        } else if (std.mem.eql(u8, arg, "--once")) {
            once = true;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return error.HelpRequested;
        } else {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            const value = args[i];
            if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--server")) {
                server_text = value;
            } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--password")) {
                secret = value;
            } else if (std.mem.eql(u8, arg, "--report-delay")) {
                report_delay = try number(u64, value, 1, 30);
            } else if (std.mem.eql(u8, arg, "--workers")) {
                workers = try number(usize, value, 1, max_workers);
            } else if (std.mem.eql(u8, arg, "--report-workers")) {
                report_workers = try number(usize, value, 1, max_report_workers);
            } else if (std.mem.eql(u8, arg, "--queue-capacity")) {
                queue_capacity = try number(usize, value, 1, max_queue_capacity);
            } else if (std.mem.eql(u8, arg, "--task-max-age")) {
                task_max_age = try number(u64, value, 1, 300);
            } else if (std.mem.eql(u8, arg, "--rpc-timeout")) {
                rpc_timeout = try number(u32, value, 1, 60);
            } else return error.UnknownArgument;
        }
    }
    if (secret.len == 0) return error.MissingSecret;
    return .{
        .allocator = allocator,
        .server = try parseServer(allocator, server_text orelse return error.MissingServer),
        .secret = secret,
        .report_delay = report_delay,
        .workers = workers,
        .report_workers = report_workers,
        .queue_capacity = queue_capacity,
        .task_max_age = task_max_age,
        .rpc_timeout_ms = rpc_timeout * 1000,
        .debug = debug,
        .once = once,
    };
}

fn number(comptime T: type, text: []const u8, min: T, max: T) !T {
    const value = std.fmt.parseInt(T, text, 10) catch return error.InvalidOptionValue;
    if (value < min or value > max) return error.InvalidOptionValue;
    return value;
}

fn parseServer(allocator: std.mem.Allocator, input: []const u8) !Server {
    if (input.len == 0) return error.InvalidServer;
    var host_part = input;
    var port_text: []const u8 = undefined;
    if (input[0] == '[') {
        const end = std.mem.indexOfScalar(u8, input, ']') orelse return error.InvalidServer;
        host_part = input[1..end];
        if (end + 1 >= input.len) return error.MissingPort;
        if (input[end + 1] != ':') return error.InvalidServer;
        port_text = input[end + 2 ..];
    } else if (std.mem.lastIndexOfScalar(u8, input, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, input[0..colon], ':') != null) return error.InvalidServer;
        host_part = input[0..colon];
        port_text = input[colon + 1 ..];
    } else return error.MissingPort;
    if (port_text.len == 0) return error.MissingPort;
    const port = try number(u16, port_text, 1, 65535);
    if (host_part.len == 0) return error.InvalidServer;
    const host = try allocator.dupe(u8, host_part);
    errdefer allocator.free(host);
    const authority = if (std.mem.indexOfScalar(u8, host_part, ':') != null)
        try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host_part, port })
    else
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host_part, port });
    return .{ .host = host, .authority = authority, .port = port };
}

test "concurrency and reporting support the thirty second workload" {
    var config = try parse(std.testing.allocator, &.{ "-p", "test", "--workers", "32", "--report-delay", "30", "--queue-capacity", "128", "-s", "[::1]:5555" });
    defer config.deinit();
    try std.testing.expectEqual(@as(usize, 32), config.workers);
    try std.testing.expectEqual(@as(u64, 30), config.report_delay);
    try std.testing.expectEqualStrings("::1", config.server.host);
    try std.testing.expectEqualStrings("[::1]:5555", config.server.authority);
}

test "resource limits and malformed arguments are rejected" {
    try std.testing.expectError(error.InvalidOptionValue, parse(std.testing.allocator, &.{ "-p", "test", "--workers", "0" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(std.testing.allocator, &.{ "-p", "test", "--workers", "65" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(std.testing.allocator, &.{ "-p", "test", "--queue-capacity", "1025" }));
    try std.testing.expectError(error.MissingArgumentValue, parse(std.testing.allocator, &.{"--workers"}));
    try std.testing.expectError(error.MissingSecret, parse(std.testing.allocator, &.{}));
}

test "server address and port must be supplied at runtime" {
    try std.testing.expectError(error.MissingServer, parse(std.testing.allocator, &.{ "-p", "test" }));
    try std.testing.expectError(error.MissingPort, parse(std.testing.allocator, &.{ "-p", "test", "-s", "dashboard.example.com" }));
    try std.testing.expectError(error.MissingPort, parse(std.testing.allocator, &.{ "-p", "test", "-s", "[::1]" }));
    try std.testing.expectError(error.InvalidServer, parse(std.testing.allocator, &.{ "-p", "test", "-s", "::1:5555" }));
}

test "one binary accepts an arbitrary configured DNS endpoint and port" {
    var config = try parse(std.testing.allocator, &.{ "--server", "dashboard.example.com:45678", "--password", "test" });
    defer config.deinit();
    try std.testing.expectEqualStrings("dashboard.example.com", config.server.host);
    try std.testing.expectEqual(@as(u16, 45678), config.server.port);
}
