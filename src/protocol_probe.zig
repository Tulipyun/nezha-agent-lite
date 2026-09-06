//! Local integration-test client. Never connects to the production dashboard.
const std = @import("std");
const h2 = @import("h2.zig");
const proto = @import("proto.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(debug_allocator.deinit() == .ok);
    const allocator = debug_allocator.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 6) return error.ExpectedHostPortCountSizeTimeoutMs;
    const port = try std.fmt.parseInt(u16, args[2], 10);
    const count = try std.fmt.parseInt(usize, args[3], 10);
    const size = try std.fmt.parseInt(usize, args[4], 10);
    const timeout_ms = try std.fmt.parseInt(u32, args[5], 10);
    const authority = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ args[1], port });
    defer allocator.free(authority);
    const payload = try allocator.alloc(u8, size);
    defer allocator.free(payload);
    @memset(payload, 'x');
    var client = try h2.Client.connectWithTimeout(allocator, authority, args[1], port, "local-test", timeout_ms);
    defer client.deinit();
    for (0..count) |_| {
        const reply = try client.unary("/test.Service/Check", payload);
        defer allocator.free(reply);
        try proto.requireReceipt(reply);
    }
    std.debug.print("accepted={d} request_bytes={d}\n", .{ count, count * (size + 5) });
}
