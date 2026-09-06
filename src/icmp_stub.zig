const std = @import("std");
const icmp = @import("icmp.zig");

pub fn ping(allocator: std.mem.Allocator, host: []const u8) !icmp.Result {
    _ = allocator;
    _ = host;
    return error.Unsupported;
}

pub fn pingWithTimeout(allocator: std.mem.Allocator, host: []const u8, timeout_ms: u32) !icmp.Result {
    _ = timeout_ms;
    return ping(allocator, host);
}
