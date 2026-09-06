//! The wire-level messages used by the v0.20.5 agent.
//!
//! This deliberately does not use reflection or a general protobuf runtime.
//! The v0.20.5 schema is small and the OpenWrt build only needs a handful of
//! messages, so a bounded hand-written codec keeps both the binary and the
//! memory footprint small.

const std = @import("std");

pub const Allocator = std.mem.Allocator;

pub const SensorTemperature = struct {
    name: []const u8 = "",
    temperature: f64 = 0,
};

pub const Host = struct {
    platform: []const u8 = "",
    platform_version: []const u8 = "",
    cpu: []const []const u8 = &.{},
    mem_total: u64 = 0,
    disk_total: u64 = 0,
    swap_total: u64 = 0,
    arch: []const u8 = "",
    virtualization: []const u8 = "",
    boot_time: u64 = 0,
    ip: []const u8 = "",
    country_code: []const u8 = "",
    version: []const u8 = "",
    gpu: []const []const u8 = &.{},
};

pub const State = struct {
    cpu: f64 = 0,
    mem_used: u64 = 0,
    swap_used: u64 = 0,
    disk_used: u64 = 0,
    net_in_transfer: u64 = 0,
    net_out_transfer: u64 = 0,
    net_in_speed: u64 = 0,
    net_out_speed: u64 = 0,
    uptime: u64 = 0,
    load1: f64 = 0,
    load5: f64 = 0,
    load15: f64 = 0,
    tcp_conn_count: u64 = 0,
    udp_conn_count: u64 = 0,
    process_count: u64 = 0,
    temperatures: []const SensorTemperature = &.{},
    gpu: f64 = 0,
};

pub const Task = struct {
    id: u64 = 0,
    type: u64 = 0,
    data: []const u8 = "",
};

pub const TaskResult = struct {
    id: u64 = 0,
    type: u64 = 0,
    delay: f32 = 0,
    data: []const u8 = "",
    successful: bool = false,
};

pub const GeoIp = struct {
    ip: []const u8 = "",
    country_code: []const u8 = "",
};

pub const Receipt = struct {
    proced: bool = false,
};

const Builder = struct {
    list: std.ArrayList(u8),
    allocator: Allocator,

    fn init(allocator: Allocator) Builder {
        return .{ .list = .empty, .allocator = allocator };
    }

    fn deinit(self: *Builder) void {
        self.list.deinit(self.allocator);
    }

    fn finish(self: *Builder) ![]u8 {
        return self.list.toOwnedSlice(self.allocator);
    }

    fn append(self: *Builder, data: []const u8) !void {
        try self.list.appendSlice(self.allocator, data);
    }

    fn varint(self: *Builder, value: u64) !void {
        var v = value;
        while (v >= 0x80) {
            try self.list.append(self.allocator, @as(u8, @intCast(v & 0x7f)) | 0x80);
            v >>= 7;
        }
        try self.list.append(self.allocator, @as(u8, @intCast(v)));
    }

    fn key(self: *Builder, field: u32, wire: u3) !void {
        try self.varint((@as(u64, field) << 3) | @as(u64, wire));
    }

    fn bytes(self: *Builder, field: u32, value: []const u8) !void {
        if (value.len == 0) return;
        try self.key(field, 2);
        try self.varint(value.len);
        try self.append(value);
    }

    fn string(self: *Builder, field: u32, value: []const u8) !void {
        try self.bytes(field, value);
    }

    fn uint(self: *Builder, field: u32, value: u64) !void {
        if (value == 0) return;
        try self.key(field, 0);
        try self.varint(value);
    }

    fn boolean(self: *Builder, field: u32, value: bool) !void {
        if (!value) return;
        try self.key(field, 0);
        try self.varint(1);
    }

    fn fixed32(self: *Builder, field: u32, value: u32) !void {
        if (value == 0) return;
        try self.key(field, 5);
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, value, .little);
        try self.append(&buf);
    }

    fn fixed64(self: *Builder, field: u32, value: u64) !void {
        if (value == 0) return;
        try self.key(field, 1);
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, value, .little);
        try self.append(&buf);
    }
};

pub fn encodeHost(allocator: Allocator, host: Host) ![]u8 {
    var b = Builder.init(allocator);
    errdefer b.deinit();

    try b.string(1, host.platform);
    try b.string(2, host.platform_version);
    for (host.cpu) |cpu| try b.string(3, cpu);
    try b.uint(4, host.mem_total);
    try b.uint(5, host.disk_total);
    try b.uint(6, host.swap_total);
    try b.string(7, host.arch);
    try b.string(8, host.virtualization);
    try b.uint(9, host.boot_time);
    try b.string(10, host.ip);
    try b.string(11, host.country_code);
    try b.string(12, host.version);
    for (host.gpu) |gpu| try b.string(13, gpu);

    return b.finish();
}

pub fn encodeState(allocator: Allocator, state: State) ![]u8 {
    var b = Builder.init(allocator);
    errdefer b.deinit();

    const cpu_bits: u64 = @bitCast(state.cpu);
    try b.fixed64(1, cpu_bits);
    try b.uint(3, state.mem_used);
    try b.uint(4, state.swap_used);
    try b.uint(5, state.disk_used);
    try b.uint(6, state.net_in_transfer);
    try b.uint(7, state.net_out_transfer);
    try b.uint(8, state.net_in_speed);
    try b.uint(9, state.net_out_speed);
    try b.uint(10, state.uptime);
    try b.fixed64(11, @as(u64, @bitCast(state.load1)));
    try b.fixed64(12, @as(u64, @bitCast(state.load5)));
    try b.fixed64(13, @as(u64, @bitCast(state.load15)));
    try b.uint(14, state.tcp_conn_count);
    try b.uint(15, state.udp_conn_count);
    try b.uint(16, state.process_count);

    for (state.temperatures) |temperature| {
        var nested = Builder.init(allocator);
        errdefer nested.deinit();
        try nested.string(1, temperature.name);
        try nested.fixed64(2, @as(u64, @bitCast(temperature.temperature)));
        const nested_bytes = try nested.finish();
        defer allocator.free(nested_bytes);
        try b.key(17, 2);
        try b.varint(nested_bytes.len);
        try b.append(nested_bytes);
    }

    try b.fixed64(18, @as(u64, @bitCast(state.gpu)));
    return b.finish();
}

pub fn encodeTaskResult(allocator: Allocator, result: TaskResult) ![]u8 {
    var b = Builder.init(allocator);
    errdefer b.deinit();
    try b.uint(1, result.id);
    try b.uint(2, result.type);
    try b.fixed32(3, @as(u32, @bitCast(result.delay)));
    try b.string(4, result.data);
    try b.boolean(5, result.successful);
    return b.finish();
}

pub fn encodeGeoIp(allocator: Allocator, geo: GeoIp) ![]u8 {
    var b = Builder.init(allocator);
    errdefer b.deinit();
    try b.string(1, geo.ip);
    try b.string(2, geo.country_code);
    return b.finish();
}

pub fn encodeReceipt(allocator: Allocator, receipt: Receipt) ![]u8 {
    var b = Builder.init(allocator);
    errdefer b.deinit();
    try b.boolean(1, receipt.proced);
    return b.finish();
}

pub const DecodeError = error{
    Truncated,
    InvalidVarint,
    InvalidWireType,
    LengthOverflow,
    MessageTooLarge,
};

const Field = struct {
    number: u32,
    wire: u3,
};

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn next(self: *Reader) DecodeError!?Field {
        if (self.pos == self.data.len) return null;
        const key_value = try self.readVarint();
        if (key_value >> 3 == 0 or key_value >> 3 > std.math.maxInt(u32)) return error.InvalidWireType;
        return .{
            .number = @intCast(key_value >> 3),
            .wire = @intCast(key_value & 7),
        };
    }

    fn readVarint(self: *Reader) DecodeError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.data.len or shift >= 64) return error.InvalidVarint;
            const byte = self.data[self.pos];
            self.pos += 1;
            if (shift == 63 and byte > 1) return error.InvalidVarint;
            result |= (@as(u64, byte & 0x7f) << shift);
            if ((byte & 0x80) == 0) return result;
            shift += 7;
        }
    }

    fn readBytes(self: *Reader, max_len: usize) DecodeError![]const u8 {
        const length = try self.readVarint();
        if (length > max_len or length > self.data.len - self.pos) return error.MessageTooLarge;
        const end = self.pos + @as(usize, @intCast(length));
        const result = self.data[self.pos..end];
        self.pos = end;
        return result;
    }

    fn readFixed32(self: *Reader) DecodeError!u32 {
        if (self.data.len - self.pos < 4) return error.Truncated;
        const result = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return result;
    }

    fn readFixed64(self: *Reader) DecodeError!u64 {
        if (self.data.len - self.pos < 8) return error.Truncated;
        const result = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return result;
    }

    fn skip(self: *Reader, wire: u3) DecodeError!void {
        switch (wire) {
            0 => _ = try self.readVarint(),
            1 => _ = try self.readFixed64(),
            2 => _ = try self.readBytes(self.data.len),
            5 => _ = try self.readFixed32(),
            else => return error.InvalidWireType,
        }
    }
};

pub fn decodeTask(data: []const u8) DecodeError!Task {
    var reader = Reader{ .data = data };
    var task = Task{};
    while (try reader.next()) |field| {
        switch (field.number) {
            1 => {
                if (field.wire == 0) task.id = try reader.readVarint() else try reader.skip(field.wire);
            },
            2 => {
                if (field.wire == 0) task.type = try reader.readVarint() else try reader.skip(field.wire);
            },
            3 => {
                if (field.wire == 2) task.data = try reader.readBytes(data.len) else try reader.skip(field.wire);
            },
            else => try reader.skip(field.wire),
        }
    }
    return task;
}

pub fn decodeReceipt(data: []const u8) DecodeError!Receipt {
    var reader = Reader{ .data = data };
    var receipt = Receipt{};
    while (try reader.next()) |field| {
        switch (field.number) {
            1 => {
                if (field.wire == 0) receipt.proced = (try reader.readVarint()) != 0 else try reader.skip(field.wire);
            },
            else => try reader.skip(field.wire),
        }
    }
    return receipt;
}

pub fn requireReceipt(data: []const u8) !void {
    const receipt = try decodeReceipt(data);
    if (!receipt.proced) return error.ServerRejected;
}

test "task protobuf round trip" {
    const allocator = std.testing.allocator;
    const encoded = try encodeTaskResult(allocator, .{
        .id = 150,
        .type = 2,
        .delay = 1.25,
        .data = "ok",
        .successful = true,
    });
    defer allocator.free(encoded);

    // The first two fields are varints and the payload is non-empty.
    try std.testing.expect(encoded.len > 8);
    const task_bytes = [_]u8{ 0x08, 0x96, 0x01, 0x10, 0x02, 0x1a, 0x03, 'a', 'b', 'c' };
    const task = try decodeTask(&task_bytes);
    try std.testing.expectEqual(@as(u64, 150), task.id);
    try std.testing.expectEqual(@as(u64, 2), task.type);
    try std.testing.expectEqualStrings("abc", task.data);
}

test "receipt protobuf" {
    const allocator = std.testing.allocator;
    const encoded = try encodeReceipt(allocator, .{ .proced = true });
    defer allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x08, 0x01 }, encoded);
    const decoded = try decodeReceipt(encoded);
    try std.testing.expect(decoded.proced);
}

test "a rejected empty or malformed receipt is never success" {
    try requireReceipt(&.{ 0x08, 0x01 });
    try std.testing.expectError(error.ServerRejected, requireReceipt(&.{ 0x08, 0x00 }));
    try std.testing.expectError(error.ServerRejected, requireReceipt(&.{}));
    try std.testing.expectError(error.InvalidVarint, requireReceipt(&.{0x08}));
}

test "host state and result bytes match the original schema with Google Protobuf" {
    const vectors = @import("testdata/proto_v0_20_5.zig");
    const allocator = std.testing.allocator;
    const host = try encodeHost(allocator, .{
        .platform = "openwrt",
        .platform_version = "24.10.8",
        .cpu = &.{"ARMv8 4 Core"},
        .mem_total = 536870912,
        .disk_total = 134217728,
        .arch = "aarch64",
        .boot_time = 1700000000,
        .version = "0.20.5-zig",
    });
    defer allocator.free(host);
    try std.testing.expectEqualSlices(u8, &vectors.host, host);
    const state = try encodeState(allocator, .{
        .cpu = 12.5,
        .mem_used = 1024,
        .swap_used = 256,
        .disk_used = 512,
        .net_in_transfer = 3000,
        .net_out_transfer = 4000,
        .net_in_speed = 30,
        .net_out_speed = 40,
        .uptime = 60,
        .load1 = 0.1,
        .load5 = 0.2,
        .load15 = 0.3,
        .tcp_conn_count = 17,
        .udp_conn_count = 8,
        .process_count = 100,
    });
    defer allocator.free(state);
    try std.testing.expectEqualSlices(u8, &vectors.state, state);
    const result = try encodeTaskResult(allocator, .{
        .id = 150,
        .type = 2,
        .delay = 1.25,
        .data = "ok",
        .successful = true,
    });
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u8, &vectors.result, result);
}
