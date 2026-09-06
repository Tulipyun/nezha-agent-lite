//! Minimal client-side clear-text HTTP/2 transport for the v0.20.5 gRPC API.
//!
//! Each connection has one active RPC at a time; unary connections are reused.
//! State reporting, task reception and result reporting own separate clients.

const std = @import("std");
const proto = @import("proto.zig");
const hpack = @import("hpack.zig");
const socket_io = @import("socket_io.zig");

const Allocator = std.mem.Allocator;

pub const MAX_FRAME_SIZE: usize = 1 << 20;
pub const MAX_MESSAGE_SIZE: usize = 4 << 20;
const HTTP2_MAX_DATA: usize = 16 * 1024;
const MAX_HEADER_SIZE: usize = 64 * 1024;
const PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

const FrameType = struct {
    const data: u8 = 0x0;
    const headers: u8 = 0x1;
    const rst_stream: u8 = 0x3;
    const settings: u8 = 0x4;
    const ping: u8 = 0x6;
    const goaway: u8 = 0x7;
    const window_update: u8 = 0x8;
    const continuation: u8 = 0x9;
};

const FrameFlags = struct {
    const end_stream: u8 = 0x1;
    const end_headers: u8 = 0x4;
    const padded: u8 = 0x8;
    const priority: u8 = 0x20;
    const ack: u8 = 0x1;
};

pub const TransportError = error{
    EndOfStream,
    FrameTooLarge,
    InvalidFrame,
    InvalidStream,
    CompressionUnsupported,
    GrpcFailure,
    ServerGoAway,
    ServerReset,
    HeaderFailure,
};

const Frame = struct {
    typ: u8,
    flags: u8,
    stream_id: u32,
    payload: []u8,
};

const SendWindow = struct {
    connection: i64 = 65535,
    stream: i64 = 65535,
    initial: u32 = 65535,
    active_id: u32 = 0,

    fn start(self: *SendWindow, id: u32) void {
        self.active_id = id;
        self.stream = self.initial;
    }

    fn credit(self: SendWindow) usize {
        return @intCast(@max(0, @min(self.connection, self.stream)));
    }

    fn consume(self: *SendWindow, amount: usize) !void {
        if (amount > self.credit()) return error.FlowControl;
        self.connection -= @intCast(amount);
        self.stream -= @intCast(amount);
    }

    fn update(self: *SendWindow, id: u32, amount: u32) !void {
        if (amount == 0 or amount > 0x7fffffff) return error.FlowControl;
        const window = if (id == 0) &self.connection else if (id == self.active_id) &self.stream else return;
        if (window.* + amount > 0x7fffffff) return error.FlowControl;
        window.* += amount;
    }

    fn setInitial(self: *SendWindow, value: u32) !void {
        if (value > 0x7fffffff) return error.FlowControl;
        const next = self.stream + @as(i64, value) - @as(i64, self.initial);
        if (next > 0x7fffffff) return error.FlowControl;
        self.stream = next;
        self.initial = value;
    }
};

pub const Client = struct {
    allocator: Allocator,
    stream: std.net.Stream,
    decoder: hpack.Decoder,
    next_stream_id: u32 = 1,
    authority: []const u8,
    secret: []const u8,
    deadline: socket_io.Deadline,
    rpc_timeout_ms: u32 = 10000,
    task_idle_timeout_ms: u32 = 120000,
    send_window: SendWindow = .{},
    buffered_frames: std.ArrayList(Frame) = .empty,
    buffered_bytes: usize = 0,

    pub fn connect(allocator: Allocator, authority: []const u8, host: []const u8, port: u16, secret: []const u8) !Client {
        return connectWithTimeout(allocator, authority, host, port, secret, 10000);
    }

    pub fn connectWithTimeout(allocator: Allocator, authority: []const u8, host: []const u8, port: u16, secret: []const u8, timeout_ms: u32) !Client {
        const deadline = try socket_io.Deadline.init(timeout_ms);
        const stream = try socket_io.connect(allocator, host, port, timeout_ms);
        var client = Client{
            .allocator = allocator,
            .stream = stream,
            .decoder = hpack.Decoder.init(allocator),
            .authority = authority,
            .secret = secret,
            .deadline = deadline,
            .rpc_timeout_ms = timeout_ms,
        };
        errdefer client.deinit();

        try socket_io.writeAll(client.stream, PREFACE, client.deadline);
        try client.writeFrame(FrameType.settings, 0, 0, &.{});
        try client.waitForSettings();
        return client;
    }

    pub fn deinit(self: *Client) void {
        for (self.buffered_frames.items) |frame| self.allocator.free(frame.payload);
        self.buffered_frames.deinit(self.allocator);
        self.decoder.deinit();
        self.stream.close();
    }

    /// Perform a unary gRPC call and return the first response message.  The
    /// returned slice belongs to `allocator` and must be freed by the caller.
    pub fn unary(self: *Client, path: []const u8, request: []const u8) ![]u8 {
        self.deadline = try socket_io.Deadline.init(self.rpc_timeout_ms);
        const stream_id = try self.takeStreamId();
        defer self.send_window.active_id = 0;
        try self.sendHeaders(stream_id, path);
        try self.sendGrpcMessage(stream_id, request, true);

        var parser = GrpcParser.init(self.allocator);
        defer parser.deinit();
        var response: ?[]u8 = null;
        errdefer if (response) |bytes| self.allocator.free(bytes);
        var headers_seen = false;
        var ended = false;
        var grpc_status: ?i32 = null;

        while (!ended) {
            const frame = try self.readFrame();
            defer self.allocator.free(frame.payload);

            if (try self.handleControl(frame)) continue;
            if (frame.stream_id != stream_id) continue;

            switch (frame.typ) {
                FrameType.headers => {
                    var info = hpack.HeaderInfo{};
                    const end_stream = try self.decodeHeaderFrame(frame, &info);
                    if (!headers_seen) {
                        headers_seen = true;
                        if (info.http_status == null or info.http_status.? != 200) return error.HeaderFailure;
                    }
                    if (info.grpc_status) |status| grpc_status = status;
                    if (end_stream) ended = true;
                },
                FrameType.data => {
                    try appendDataFrame(&parser, frame);
                    try self.ackDataWindow(frame.stream_id, frame.payload.len);
                    while (try parser.takeMessage()) |message| {
                        if (response != null) {
                            self.allocator.free(message);
                            return error.InvalidFrame;
                        }
                        response = message;
                    }
                    if ((frame.flags & FrameFlags.end_stream) != 0) ended = true;
                },
                FrameType.rst_stream => return error.ServerReset,
                else => {},
            }
        }

        if (grpc_status == null or grpc_status.? != 0) return error.GrpcFailure;
        if (!headers_seen or parser.pending.items.len != 0) return error.InvalidFrame;
        return response orelse error.InvalidFrame;
    }

    pub fn openTaskStream(self: *Client, request: []const u8) !TaskStream {
        self.deadline = try socket_io.Deadline.init(self.rpc_timeout_ms);
        const stream_id = try self.takeStreamId();
        try self.sendHeaders(stream_id, "/proto.NezhaService/RequestTask");
        try self.sendGrpcMessage(stream_id, request, true);
        return .{
            .client = self,
            .stream_id = stream_id,
            .parser = GrpcParser.init(self.allocator),
        };
    }

    fn takeStreamId(self: *Client) !u32 {
        if (self.next_stream_id > 0x7ffffffd) return error.StreamIdsExhausted;
        const id = self.next_stream_id;
        self.next_stream_id += 2;
        self.send_window.start(id);
        return id;
    }

    fn waitForSettings(self: *Client) !void {
        while (true) {
            const frame = try self.readFrame();
            defer self.allocator.free(frame.payload);
            switch (frame.typ) {
                FrameType.settings => {
                    _ = try self.handleControl(frame);
                    if ((frame.flags & FrameFlags.ack) == 0) return;
                },
                FrameType.ping => {
                    if ((frame.flags & FrameFlags.ack) == 0 and frame.payload.len == 8) {
                        try self.writeFrame(FrameType.ping, FrameFlags.ack, 0, frame.payload);
                    }
                },
                FrameType.goaway => return error.ServerGoAway,
                else => {},
            }
        }
    }

    fn sendHeaders(self: *Client, stream_id: u32, path: []const u8) !void {
        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(self.allocator);

        // Literal-without-indexing fields are intentionally used throughout.
        // This avoids mutating the peer's dynamic table and works with both
        // grpc-go and the small decoder in this project.
        try hpack.appendLiteralHeader(&block, self.allocator, ":method", "POST");
        try hpack.appendLiteralHeader(&block, self.allocator, ":scheme", "http");
        try hpack.appendLiteralHeader(&block, self.allocator, ":path", path);
        try hpack.appendLiteralHeader(&block, self.allocator, ":authority", self.authority);
        try hpack.appendLiteralHeader(&block, self.allocator, "content-type", "application/grpc");
        try hpack.appendLiteralHeader(&block, self.allocator, "te", "trailers");
        try hpack.appendLiteralHeader(&block, self.allocator, "client_secret", self.secret);
        try hpack.appendLiteralHeader(&block, self.allocator, "user-agent", "nezha-agent-zig/0.1");
        if (!std.mem.eql(u8, path, "/proto.NezhaService/RequestTask")) {
            var timeout_buf: [24]u8 = undefined;
            const timeout = try std.fmt.bufPrint(&timeout_buf, "{d}m", .{self.rpc_timeout_ms});
            try hpack.appendLiteralHeader(&block, self.allocator, "grpc-timeout", timeout);
        }
        try self.writeFrame(FrameType.headers, FrameFlags.end_headers, stream_id, block.items);
    }

    fn sendGrpcMessage(self: *Client, stream_id: u32, message: []const u8, end_stream: bool) !void {
        if (message.len > MAX_MESSAGE_SIZE) return error.FrameTooLarge;
        var envelope: std.ArrayList(u8) = .empty;
        defer envelope.deinit(self.allocator);
        try envelope.append(self.allocator, 0); // uncompressed
        var length_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &length_buf, @intCast(message.len), .big);
        try envelope.appendSlice(self.allocator, &length_buf);
        try envelope.appendSlice(self.allocator, message);

        var offset: usize = 0;
        while (offset < envelope.items.len) {
            while (self.send_window.credit() == 0) try self.receiveSendCredit();
            const remaining = envelope.items.len - offset;
            const chunk = @min(remaining, HTTP2_MAX_DATA, self.send_window.credit());
            const is_last = offset + chunk == envelope.items.len;
            const flags: u8 = if (is_last and end_stream) FrameFlags.end_stream else 0;
            try self.writeFrame(FrameType.data, flags, stream_id, envelope.items[offset .. offset + chunk]);
            try self.send_window.consume(chunk);
            offset += chunk;
        }
    }

    fn readFrame(self: *Client) !Frame {
        if (self.buffered_frames.items.len > 0) {
            const frame = self.buffered_frames.orderedRemove(0);
            self.buffered_bytes -= frame.payload.len + 9;
            return frame;
        }
        return self.readWireFrame();
    }

    fn receiveSendCredit(self: *Client) !void {
        const frame = try self.readWireFrame();
        var retained = false;
        defer if (!retained) self.allocator.free(frame.payload);
        if (try self.handleControl(frame)) return;
        if (frame.typ == FrameType.rst_stream and frame.stream_id == self.send_window.active_id) return error.ServerReset;
        // A peer may send response headers before granting more DATA credit.
        // Keep their order and HPACK state until the response reader consumes them.
        if (frame.payload.len + 9 > MAX_HEADER_SIZE -| self.buffered_bytes) return error.FrameTooLarge;
        try self.buffered_frames.append(self.allocator, frame);
        self.buffered_bytes += frame.payload.len + 9;
        retained = true;
    }

    fn readWireFrame(self: *Client) !Frame {
        var header: [9]u8 = undefined;
        try socket_io.readExact(self.stream, &header, self.deadline);
        const length: usize = (@as(usize, header[0]) << 16) | (@as(usize, header[1]) << 8) | header[2];
        if (length > MAX_FRAME_SIZE) return error.FrameTooLarge;
        const stream_id: u32 = (@as(u32, header[5] & 0x7f) << 24) |
            (@as(u32, header[6]) << 16) | (@as(u32, header[7]) << 8) | header[8];
        const payload = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(payload);
        try socket_io.readExact(self.stream, payload, self.deadline);
        return .{ .typ = header[3], .flags = header[4], .stream_id = stream_id, .payload = payload };
    }

    fn writeFrame(self: *Client, typ: u8, flags: u8, stream_id: u32, payload: []const u8) !void {
        if (payload.len > 0xffffff or (stream_id & 0x80000000) != 0) return error.FrameTooLarge;
        var header: [9]u8 = undefined;
        header[0] = @intCast((payload.len >> 16) & 0xff);
        header[1] = @intCast((payload.len >> 8) & 0xff);
        header[2] = @intCast(payload.len & 0xff);
        header[3] = typ;
        header[4] = flags;
        header[5] = @intCast((stream_id >> 24) & 0x7f);
        header[6] = @intCast((stream_id >> 16) & 0xff);
        header[7] = @intCast((stream_id >> 8) & 0xff);
        header[8] = @intCast(stream_id & 0xff);
        try socket_io.writeAll(self.stream, &header, self.deadline);
        try socket_io.writeAll(self.stream, payload, self.deadline);
    }

    fn handleControl(self: *Client, frame: Frame) !bool {
        switch (frame.typ) {
            FrameType.settings => {
                if (frame.stream_id != 0 or frame.payload.len % 6 != 0) return error.InvalidFrame;
                if ((frame.flags & FrameFlags.ack) != 0) {
                    if (frame.payload.len != 0) return error.InvalidFrame;
                    return true;
                }
                var offset: usize = 0;
                while (offset < frame.payload.len) : (offset += 6) {
                    const id = std.mem.readInt(u16, frame.payload[offset..][0..2], .big);
                    const value = std.mem.readInt(u32, frame.payload[offset + 2 ..][0..4], .big);
                    switch (id) {
                        2 => if (value > 1) return error.InvalidFrame,
                        4 => try self.send_window.setInitial(value),
                        5 => if (value < 16384 or value > 0xffffff) return error.InvalidFrame,
                        else => {},
                    }
                }
                try self.writeFrame(FrameType.settings, FrameFlags.ack, 0, &.{});
                return true;
            },
            FrameType.ping => {
                if (frame.stream_id != 0 or frame.payload.len != 8) return error.InvalidFrame;
                if ((frame.flags & FrameFlags.ack) == 0) {
                    try self.writeFrame(FrameType.ping, FrameFlags.ack, 0, frame.payload);
                }
                return true;
            },
            FrameType.goaway => return error.ServerGoAway,
            FrameType.window_update => {
                if (frame.payload.len != 4) return error.InvalidFrame;
                const amount = std.mem.readInt(u32, frame.payload[0..4], .big) & 0x7fffffff;
                try self.send_window.update(frame.stream_id, amount);
                return true;
            },
            else => return false,
        }
    }

    fn decodeHeaderFrame(self: *Client, frame: Frame, info: *hpack.HeaderInfo) !bool {
        var block: std.ArrayList(u8) = .empty;
        defer block.deinit(self.allocator);

        var start: usize = 0;
        var end: usize = frame.payload.len;
        var pad_len: usize = 0;
        if ((frame.flags & FrameFlags.padded) != 0) {
            if (frame.payload.len == 0) return error.InvalidFrame;
            pad_len = frame.payload[0];
            start = 1;
        }
        if ((frame.flags & FrameFlags.priority) != 0) start += 5;
        if (start > end or pad_len > end - start) return error.InvalidFrame;
        end -= pad_len;
        if (end - start > MAX_HEADER_SIZE) return error.FrameTooLarge;
        try block.appendSlice(self.allocator, frame.payload[start..end]);

        var end_headers = (frame.flags & FrameFlags.end_headers) != 0;
        while (!end_headers) {
            const continuation = try self.readFrame();
            defer self.allocator.free(continuation.payload);
            if (continuation.typ != FrameType.continuation or continuation.stream_id != frame.stream_id) return error.InvalidFrame;
            if (continuation.payload.len > MAX_HEADER_SIZE -| block.items.len) return error.FrameTooLarge;
            try block.appendSlice(self.allocator, continuation.payload);
            end_headers = (continuation.flags & FrameFlags.end_headers) != 0;
        }
        self.decoder.decode(block.items, info) catch return error.HeaderFailure;
        return (frame.flags & FrameFlags.end_stream) != 0;
    }

    fn appendDataFrame(parser: *GrpcParser, frame: Frame) !void {
        var start: usize = 0;
        var end: usize = frame.payload.len;
        if ((frame.flags & FrameFlags.padded) != 0) {
            if (frame.payload.len == 0) return error.InvalidFrame;
            const pad_len: usize = frame.payload[0];
            start = 1;
            if (pad_len > end - start) return error.InvalidFrame;
            end -= pad_len;
        }
        try parser.append(frame.payload[start..end]);
    }

    fn ackDataWindow(self: *Client, stream_id: u32, amount: usize) !void {
        if (amount == 0) return;
        const increment: u32 = @intCast(@min(amount, 0x7fffffff));
        var payload: [4]u8 = undefined;
        std.mem.writeInt(u32, &payload, increment, .big);
        try self.writeFrame(FrameType.window_update, 0, stream_id, &payload);
        try self.writeFrame(FrameType.window_update, 0, 0, &payload);
    }
};

pub const TaskStream = struct {
    client: *Client,
    stream_id: u32,
    parser: GrpcParser,
    headers_seen: bool = false,
    ended: bool = false,
    last_message: ?[]u8 = null,
    grpc_status: ?i32 = null,

    pub fn deinit(self: *TaskStream) void {
        if (self.last_message) |message| self.client.allocator.free(message);
        self.parser.deinit();
    }

    /// Return the next task.  The returned task's `data` points into an
    /// internal message buffer and is valid until the next call to `next` or
    /// `deinit`; callers that queue work must copy it first.
    pub fn next(self: *TaskStream) !?proto.Task {
        self.client.deadline = try socket_io.Deadline.init(self.client.task_idle_timeout_ms);
        if (self.last_message) |message| {
            self.client.allocator.free(message);
            self.last_message = null;
        }
        if (try self.takePendingTask()) |task| return task;
        while (!self.ended) {
            const frame = try self.client.readFrame();
            defer self.client.allocator.free(frame.payload);
            self.client.deadline = try socket_io.Deadline.init(self.client.task_idle_timeout_ms);

            if (try self.client.handleControl(frame)) continue;
            if (frame.stream_id != self.stream_id) continue;

            switch (frame.typ) {
                FrameType.headers => {
                    var info = hpack.HeaderInfo{};
                    const end_stream = try self.client.decodeHeaderFrame(frame, &info);
                    if (!self.headers_seen) {
                        self.headers_seen = true;
                        if (info.http_status == null or info.http_status.? != 200) return error.HeaderFailure;
                    }
                    if (info.grpc_status) |status| self.grpc_status = status;
                    if (end_stream) self.ended = true;
                },
                FrameType.data => {
                    try Client.appendDataFrame(&self.parser, frame);
                    try self.client.ackDataWindow(frame.stream_id, frame.payload.len);
                    if ((frame.flags & FrameFlags.end_stream) != 0) self.ended = true;
                },
                FrameType.rst_stream => return error.ServerReset,
                else => {},
            }

            if (try self.takePendingTask()) |task| return task;
        }
        if (self.parser.pending.items.len != 0) return error.InvalidFrame;
        if (self.grpc_status == null or self.grpc_status.? != 0) return error.GrpcFailure;
        return null;
    }

    fn takePendingTask(self: *TaskStream) !?proto.Task {
        const message = (try self.parser.takeMessage()) orelse return null;
        const task = proto.decodeTask(message) catch {
            self.client.allocator.free(message);
            return error.InvalidFrame;
        };
        self.last_message = message;
        return task;
    }
};

const GrpcParser = struct {
    allocator: Allocator,
    pending: std.ArrayList(u8) = .empty,

    fn init(allocator: Allocator) GrpcParser {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *GrpcParser) void {
        self.pending.deinit(self.allocator);
    }

    fn append(self: *GrpcParser, bytes: []const u8) !void {
        if (bytes.len > MAX_MESSAGE_SIZE + 5 -| self.pending.items.len) return error.FrameTooLarge;
        try self.pending.appendSlice(self.allocator, bytes);
    }

    fn takeMessage(self: *GrpcParser) !?[]u8 {
        if (self.pending.items.len < 5) return null;
        if (self.pending.items[0] != 0) return error.CompressionUnsupported;
        const length: usize = std.mem.readInt(u32, self.pending.items[1..5], .big);
        if (length > MAX_MESSAGE_SIZE) return error.FrameTooLarge;
        if (self.pending.items.len < 5 + length) return null;

        const message = try self.allocator.alloc(u8, length);
        @memcpy(message, self.pending.items[5 .. 5 + length]);
        const remaining = self.pending.items.len - (5 + length);
        if (remaining > 0) std.mem.copyForwards(u8, self.pending.items[0..remaining], self.pending.items[5 + length ..]);
        self.pending.items.len = remaining;
        return message;
    }
};

test "grpc envelope parser" {
    const allocator = std.testing.allocator;
    var parser = GrpcParser.init(allocator);
    defer parser.deinit();
    const bytes = [_]u8{ 0, 0, 0, 0, 3, 'a', 'b', 'c' };
    try parser.append(bytes[0..3]);
    try std.testing.expect((try parser.takeMessage()) == null);
    try parser.append(bytes[3..]);
    const message = (try parser.takeMessage()) orelse return error.TestExpectedEqual;
    defer allocator.free(message);
    try std.testing.expectEqualStrings("abc", message);
}

test "grpc envelope parser handles coalesced messages" {
    const allocator = std.testing.allocator;
    var parser = GrpcParser.init(allocator);
    defer parser.deinit();
    const bytes = [_]u8{
        0, 0, 0, 0, 1, 'a',
        0, 0, 0, 0, 1, 'b',
    };
    try parser.append(&bytes);
    const first = (try parser.takeMessage()) orelse return error.TestExpectedEqual;
    defer allocator.free(first);
    const second = (try parser.takeMessage()) orelse return error.TestExpectedEqual;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("a", first);
    try std.testing.expectEqualStrings("b", second);
}

test "send windows enforce connection credit across many unary calls" {
    var window = SendWindow{};
    for (0..65) |i| {
        window.start(@intCast(i * 2 + 1));
        try window.consume(1000);
    }
    window.start(131);
    try std.testing.expectEqual(@as(usize, 535), window.credit());
    try std.testing.expectError(error.FlowControl, window.consume(1000));
    try window.update(0, 65000);
    try window.consume(1000);
}

test "stream window reductions can be negative and updates cannot overflow" {
    var window = SendWindow{};
    window.start(1);
    try window.consume(100);
    try window.setInitial(32);
    try std.testing.expectEqual(@as(usize, 0), window.credit());
    try window.update(1, 100);
    try std.testing.expectEqual(@as(usize, 32), window.credit());
    try std.testing.expectError(error.FlowControl, window.update(0, 0));
    try std.testing.expectError(error.FlowControl, window.update(0, 0x7fffffff));
}
