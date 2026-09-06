//! Bounded Linux ICMP probes with source, sequence and per-task nonce matching.
const std = @import("std");
const posix = std.posix;
const icmp = @import("icmp.zig");
const packet_codec = @import("icmp_packet.zig");
var next_nonce: std.atomic.Value(u32) = .init(1);

pub fn ping(allocator: std.mem.Allocator, host: []const u8) !icmp.Result {
    return pingWithTimeout(allocator, host, 20000);
}

pub fn pingWithTimeout(allocator: std.mem.Allocator, host: []const u8, timeout_ms: u32) !icmp.Result {
    var timer = try std.time.Timer.start();
    const budget_ns = @as(u64, timeout_ms) * std.time.ns_per_ms;
    const addresses = std.net.getAddressList(allocator, host, 0) catch return error.ResolveFailed;
    defer addresses.deinit();
    if (timer.read() >= budget_ns) return error.Timeout;
    var selected: ?std.net.Address = null;
    for (addresses.addrs) |address| {
        if (address.any.family == posix.AF.INET) {
            selected = address;
            break;
        }
    }
    if (selected == null and addresses.addrs.len > 0) selected = addresses.addrs[0];
    const address = selected orelse return error.NoAddress;
    const ipv6 = address.any.family == posix.AF.INET6;
    const protocol: u32 = if (ipv6) posix.IPPROTO.ICMPV6 else posix.IPPROTO.ICMP;
    var datagram_socket = true;
    const flags = posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK;
    const fd = posix.socket(address.any.family, posix.SOCK.DGRAM | flags, protocol) catch blk: {
        datagram_socket = false;
        break :blk try posix.socket(address.any.family, posix.SOCK.RAW | flags, protocol);
    };
    defer posix.close(fd);

    const nonce = (@as(u64, @intCast(std.os.linux.getpid())) << 32) | next_nonce.fetchAdd(1, .monotonic);
    const identifier: u16 = @truncate(nonce);
    var received: u32 = 0;
    var total_ns: u64 = 0;
    var sequence: u16 = 1;
    var packet: [packet_codec.packet_size]u8 = undefined;
    var reply: [2048]u8 = undefined;
    while (sequence <= 5 and timer.read() < budget_ns) : (sequence += 1) {
        packet_codec.request(&packet, ipv6, identifier, sequence, nonce);
        const started = timer.read();
        const deadline = @min(budget_ns, started + 4 * std.time.ns_per_s);
        _ = posix.sendto(fd, &packet, 0, &address.any, address.getOsSockLen()) catch continue;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        while (true) {
            const now = timer.read();
            if (now >= deadline) break;
            const remaining_ms: i32 = @intCast((deadline - now + std.time.ns_per_ms - 1) / std.time.ns_per_ms);
            fds[0].revents = 0;
            const ready = try posix.poll(&fds, remaining_ms);
            if (ready == 0 or (fds[0].revents & posix.POLL.IN) == 0) break;
            var source: std.net.Address = undefined;
            var source_len: posix.socklen_t = @sizeOf(std.net.Address);
            const n = posix.recvfrom(fd, &reply, 0, &source.any, &source_len) catch |err| switch (err) {
                error.WouldBlock => continue,
                else => break,
            };
            if (sameHost(address, source) and packet_codec.matches(reply[0..n], ipv6, identifier, sequence, nonce, !datagram_socket)) {
                received += 1;
                total_ns += timer.read() - started;
                break;
            }
        }
    }
    if (received == 0) return .{ .message = "packets recv 0" };
    return .{
        .successful = true,
        .delay_ms = @floatCast(@as(f64, @floatFromInt(total_ns)) / (@as(f64, @floatFromInt(received)) * std.time.ns_per_ms)),
        .received = received,
    };
}

fn sameHost(expected: std.net.Address, actual: std.net.Address) bool {
    if (expected.any.family != actual.any.family) return false;
    if (expected.any.family == posix.AF.INET) return expected.in.sa.addr == actual.in.sa.addr;
    if (expected.any.family == posix.AF.INET6) return std.mem.eql(u8, &expected.in6.sa.addr, &actual.in6.sa.addr);
    return false;
}
