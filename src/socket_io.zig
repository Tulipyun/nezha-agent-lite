//! Nonblocking sockets with monotonic deadlines shared by every step of an RPC.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Deadline = struct {
    start: std.time.Instant,
    budget_ns: u64,

    pub fn init(timeout_ms: u32) !Deadline {
        return .{ .start = try std.time.Instant.now(), .budget_ns = @as(u64, timeout_ms) * std.time.ns_per_ms };
    }

    pub fn remainingMs(self: Deadline) !i32 {
        const elapsed = (try std.time.Instant.now()).since(self.start);
        if (elapsed >= self.budget_ns) return error.Timeout;
        return @intCast(@min(std.math.maxInt(i32), (self.budget_ns - elapsed + std.time.ns_per_ms - 1) / std.time.ns_per_ms));
    }
};

pub fn wait(stream: std.net.Stream, events: i16, deadline: Deadline) !void {
    var fds = [_]posix.pollfd{.{ .fd = stream.handle, .events = events, .revents = 0 }};
    while (true) {
        const ready = try posix.poll(&fds, try deadline.remainingMs());
        if (ready == 0) return error.Timeout;
        if ((fds[0].revents & posix.POLL.NVAL) != 0) return error.EndOfStream;
        // HUP/ERR must be consumed by recv/send/getsockopt, not retried forever.
        if ((fds[0].revents & (events | posix.POLL.HUP | posix.POLL.ERR)) != 0) return;
    }
}

pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16, timeout_ms: u32) !std.net.Stream {
    // Resolution uses the platform resolver's own timeout. TCP and the HTTP/2
    // handshake are separately bounded; no thread is spawned per DNS lookup.
    const addresses = try std.net.getAddressList(allocator, host, port);
    defer addresses.deinit();
    const deadline = try Deadline.init(timeout_ms);
    var last_error: anyerror = error.UnknownHostName;
    for (addresses.addrs) |address| {
        return connectAddress(address, deadline) catch |err| {
            last_error = err;
            continue;
        };
    }
    return last_error;
}

fn connectAddress(address: std.net.Address, deadline: Deadline) !std.net.Stream {
    _ = try deadline.remainingMs();
    const fd = try posix.socket(address.any.family, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC, posix.IPPROTO.TCP);
    const stream = std.net.Stream{ .handle = fd };
    errdefer stream.close();
    posix.connect(fd, &address.any, address.getOsSockLen()) catch |err| switch (err) {
        error.WouldBlock, error.ConnectionPending => {
            try wait(stream, posix.POLL.OUT, deadline);
            if (builtin.os.tag == .windows) {
                const ws = std.os.windows.ws2_32;
                var code: i32 = 0;
                var size: i32 = @sizeOf(i32);
                if (ws.getsockopt(fd, ws.SOL.SOCKET, ws.SO.ERROR, @ptrCast(&code), &size) != 0 or code != 0) return error.ConnectionRefused;
            } else {
                try posix.getsockoptError(fd);
            }
        },
        else => return err,
    };
    return stream;
}

pub fn readExact(stream: std.net.Stream, buffer: []u8, deadline: Deadline) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        _ = try deadline.remainingMs();
        const n = posix.recv(stream.handle, buffer[offset..], 0) catch |err| switch (err) {
            error.WouldBlock => {
                try wait(stream, posix.POLL.IN, deadline);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

pub fn writeAll(stream: std.net.Stream, bytes: []const u8, deadline: Deadline) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        _ = try deadline.remainingMs();
        const flags = if (builtin.os.tag == .linux) posix.MSG.NOSIGNAL else 0;
        const n = posix.send(stream.handle, bytes[offset..], flags) catch |err| switch (err) {
            error.WouldBlock => {
                try wait(stream, posix.POLL.OUT, deadline);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        offset += n;
    }
}

test "zero deadline expires immediately" {
    const deadline = try Deadline.init(0);
    try std.testing.expectError(error.Timeout, deadline.remainingMs());
}
