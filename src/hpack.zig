//! Small HPACK codec used by the client-side h2c transport.
//!
//! Header blocks sent by this agent use literal-without-indexing fields, so
//! the encoder is intentionally tiny.  The decoder accepts all field forms
//! commonly emitted by grpc-go, including indexed fields and Huffman strings.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const HeaderInfo = struct {
    http_status: ?u16 = null,
    grpc_status: ?i32 = null,
    grpc_message: [256]u8 = undefined,
    grpc_message_len: usize = 0,
};

const Header = struct {
    name: []const u8,
    value: []const u8,
};

const StaticEntry = struct {
    name: []const u8,
    value: []const u8,
};

// RFC 7541 Appendix A.
const static_table = [_]StaticEntry{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

const DynamicEntry = struct {
    name: []u8,
    value: []u8,
};

pub const DecodeError = error{
    Truncated,
    InvalidInteger,
    InvalidIndex,
    InvalidString,
    InvalidHuffman,
    HeaderTooLarge,
};

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn byte(self: *Cursor) DecodeError!u8 {
        if (self.pos >= self.data.len) return error.Truncated;
        const b = self.data[self.pos];
        self.pos += 1;
        return b;
    }

    fn bytes(self: *Cursor, len: usize) DecodeError![]const u8 {
        if (len > self.data.len - self.pos) return error.Truncated;
        const result = self.data[self.pos .. self.pos + len];
        self.pos += len;
        return result;
    }
};

pub const Decoder = struct {
    allocator: Allocator,
    dynamic: std.ArrayList(DynamicEntry) = .empty,
    dynamic_size: usize = 0,
    max_dynamic_size: usize = 4096,

    pub fn init(allocator: Allocator) Decoder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Decoder) void {
        for (self.dynamic.items) |entry| {
            self.allocator.free(entry.name);
            self.allocator.free(entry.value);
        }
        self.dynamic.deinit(self.allocator);
    }

    pub fn decode(self: *Decoder, block: []const u8, info: *HeaderInfo) DecodeError!void {
        var cursor = Cursor{ .data = block };
        while (cursor.pos < block.len) {
            const first = try cursor.byte();
            if ((first & 0x80) != 0) {
                const index = try decodeInteger(&cursor, first, 7);
                const header = self.indexed(index) orelse return error.InvalidIndex;
                try self.observe(header.name, header.value, info);
            } else if ((first & 0x40) != 0) {
                const index = try decodeInteger(&cursor, first, 6);
                const name = try self.decodeName(&cursor, index);
                errdefer self.allocator.free(name);
                const value = try self.decodeString(&cursor);
                errdefer self.allocator.free(value);
                try self.observe(name, value, info);
                try self.insertOwned(name, value);
            } else if ((first & 0x20) != 0) {
                const size = try decodeInteger(&cursor, first, 5);
                if (size > 4096) return error.HeaderTooLarge;
                self.setMaxDynamicSize(size);
            } else {
                const index = try decodeInteger(&cursor, first, 4);
                const name = try self.decodeName(&cursor, index);
                defer self.allocator.free(name);
                const value = try self.decodeString(&cursor);
                defer self.allocator.free(value);
                try self.observe(name, value, info);
            }
        }
    }

    fn indexed(self: *Decoder, index: u32) ?Header {
        if (index == 0) return null;
        if (index <= static_table.len) {
            const entry = static_table[index - 1];
            return .{ .name = entry.name, .value = entry.value };
        }
        const dynamic_index = index - static_table.len;
        if (dynamic_index == 0 or dynamic_index > self.dynamic.items.len) return null;
        const entry = self.dynamic.items[self.dynamic.items.len - dynamic_index];
        return .{ .name = entry.name, .value = entry.value };
    }

    fn decodeName(self: *Decoder, cursor: *Cursor, index: u32) DecodeError![]u8 {
        if (index == 0) return self.decodeString(cursor);
        const header = self.indexed(index) orelse return error.InvalidIndex;
        return self.allocator.dupe(u8, header.name) catch return error.HeaderTooLarge;
    }

    fn decodeString(self: *Decoder, cursor: *Cursor) DecodeError![]u8 {
        const first = try cursor.byte();
        const length = try decodeInteger(cursor, first, 7);
        if (length > 65536) return error.HeaderTooLarge;
        const encoded = try cursor.bytes(length);
        if ((first & 0x80) == 0) {
            return self.allocator.dupe(u8, encoded) catch return error.HeaderTooLarge;
        }
        return decodeHuffman(self.allocator, encoded) catch error.InvalidHuffman;
    }

    fn observe(self: *Decoder, name: []const u8, value: []const u8, info: *HeaderInfo) DecodeError!void {
        _ = self;
        if (std.mem.eql(u8, name, ":status")) {
            const status = parseUnsigned(value) orelse return error.InvalidString;
            if (status > std.math.maxInt(u16)) return error.InvalidString;
            info.http_status = @intCast(status);
        } else if (std.mem.eql(u8, name, "grpc-status")) {
            const status = parseUnsigned(value) orelse return error.InvalidString;
            if (status > std.math.maxInt(i32)) return error.InvalidString;
            info.grpc_status = @intCast(status);
        } else if (std.mem.eql(u8, name, "grpc-message")) {
            info.grpc_message_len = @min(value.len, info.grpc_message.len);
            @memcpy(info.grpc_message[0..info.grpc_message_len], value[0..info.grpc_message_len]);
        }
    }

    fn setMaxDynamicSize(self: *Decoder, requested: u32) void {
        // The server normally advertises 4096.  Keep a hard bound for an
        // untrusted peer; reducing the table is valid HPACK behavior.
        self.max_dynamic_size = @min(@as(usize, requested), 4096);
        while (self.dynamic_size > self.max_dynamic_size and self.dynamic.items.len > 0) {
            const old = self.dynamic.orderedRemove(0);
            self.dynamic_size -= entrySize(old);
            self.allocator.free(old.name);
            self.allocator.free(old.value);
        }
    }

    fn insertOwned(self: *Decoder, name: []u8, value: []u8) DecodeError!void {
        const size = entrySize(.{ .name = name, .value = value });
        if (size > self.max_dynamic_size) {
            const limit = self.max_dynamic_size;
            self.setMaxDynamicSize(0);
            self.max_dynamic_size = limit;
            self.allocator.free(name);
            self.allocator.free(value);
            return;
        }
        while (self.dynamic_size + size > self.max_dynamic_size and self.dynamic.items.len > 0) {
            const old = self.dynamic.orderedRemove(0);
            self.dynamic_size -= entrySize(old);
            self.allocator.free(old.name);
            self.allocator.free(old.value);
        }
        self.dynamic.append(self.allocator, .{ .name = name, .value = value }) catch {
            return error.HeaderTooLarge;
        };
        self.dynamic_size += size;
    }
};

fn entrySize(entry: DynamicEntry) usize {
    return 32 + entry.name.len + entry.value.len;
}

fn decodeInteger(cursor: *Cursor, first: u8, comptime prefix: u3) DecodeError!u32 {
    const mask: u8 = (@as(u8, 1) << prefix) - 1;
    var value: u32 = first & mask;
    if (value < mask) return value;

    var shift: u5 = 0;
    while (true) {
        const b = try cursor.byte();
        if (shift > 28 or (shift == 28 and (b & 0x7f) > 0x0f)) return error.InvalidInteger;
        value = std.math.add(u32, value, @as(u32, b & 0x7f) << shift) catch return error.InvalidInteger;
        if ((b & 0x80) == 0) return value;
        if (shift >= 28) return error.InvalidInteger;
        shift += 7;
    }
}

fn parseUnsigned(value: []const u8) ?u32 {
    if (value.len == 0) return null;
    var result: u32 = 0;
    for (value) |c| {
        if (c < '0' or c > '9') return null;
        const digit: u32 = c - '0';
        if (result > (std.math.maxInt(u32) - digit) / 10) return null;
        result = result * 10 + digit;
    }
    return result;
}

pub fn appendLiteralHeader(list: *std.ArrayList(u8), allocator: Allocator, name: []const u8, value: []const u8) !void {
    // Literal header field without indexing, new name (0000xxxx, index 0).
    try list.append(allocator, 0);
    try appendString(list, allocator, name);
    try appendString(list, allocator, value);
}

fn appendString(list: *std.ArrayList(u8), allocator: Allocator, value: []const u8) !void {
    try appendInteger(list, allocator, @intCast(value.len), 7, 0);
    try list.appendSlice(allocator, value);
}

fn appendInteger(list: *std.ArrayList(u8), allocator: Allocator, value: u32, comptime prefix: u3, first_bits: u8) !void {
    const mask: u32 = (@as(u32, 1) << prefix) - 1;
    if (value < mask) {
        try list.append(allocator, first_bits | @as(u8, @intCast(value)));
        return;
    }
    try list.append(allocator, first_bits | @as(u8, @intCast(mask)));
    var remaining = value - mask;
    while (remaining >= 128) {
        try list.append(allocator, @as(u8, @intCast(remaining & 0x7f)) | 0x80);
        remaining >>= 7;
    }
    try list.append(allocator, @as(u8, @intCast(remaining)));
}

// RFC 7541 Huffman code tables.  Kept as separate arrays so the decoder has
// no heap-allocated trie and remains small on the router.
const huffman_codes = [_]u32{
    0x1ff8,    0x7fffd8,  0xfffffe2,  0xfffffe3, 0xfffffe4, 0xfffffe5,  0xfffffe6,  0xfffffe7,
    0xfffffe8, 0xffffea,  0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb,  0xfffffec,
    0xfffffed, 0xfffffee, 0xfffffef,  0xffffff0, 0xffffff1, 0xffffff2,  0x3ffffffe, 0xffffff3,
    0xffffff4, 0xffffff5, 0xffffff6,  0xffffff7, 0xffffff8, 0xffffff9,  0xffffffa,  0xffffffb,
    0x14,      0x3f8,     0x3f9,      0xffa,     0x1ff9,    0x15,       0xf8,       0x7fa,
    0x3fa,     0x3fb,     0xf9,       0x7fb,     0xfa,      0x16,       0x17,       0x18,
    0x0,       0x1,       0x2,        0x19,      0x1a,      0x1b,       0x1c,       0x1d,
    0x1e,      0x1f,      0x5c,       0xfb,      0x7ffc,    0x20,       0xffb,      0x3fc,
    0x1ffa,    0x21,      0x5d,       0x5e,      0x5f,      0x60,       0x61,       0x62,
    0x63,      0x64,      0x65,       0x66,      0x67,      0x68,       0x69,       0x6a,
    0x6b,      0x6c,      0x6d,       0x6e,      0x6f,      0x70,       0x71,       0x72,
    0xfc,      0x73,      0xfd,       0x1ffb,    0x7fff0,   0x1ffc,     0x3ffc,     0x22,
    0x7ffd,    0x3,       0x23,       0x4,       0x24,      0x5,        0x25,       0x26,
    0x27,      0x6,       0x74,       0x75,      0x28,      0x29,       0x2a,       0x7,
    0x2b,      0x76,      0x2c,       0x8,       0x9,       0x2d,       0x77,       0x78,
    0x79,      0x7a,      0x7b,       0x7ffe,    0x7fc,     0x3ffd,     0x1ffd,     0xffffffc,
    0xfffe6,   0x3fffd2,  0xfffe7,    0xfffe8,   0x3fffd3,  0x3fffd4,   0x3fffd5,   0x7fffd9,
    0x3fffd6,  0x7fffda,  0x7fffdb,   0x7fffdc,  0x7fffdd,  0x7fffde,   0xffffeb,   0x7fffdf,
    0xffffec,  0xffffed,  0x3fffd7,   0x7fffe0,  0xffffee,  0x7fffe1,   0x7fffe2,   0x7fffe3,
    0x7fffe4,  0x1fffdc,  0x3fffd8,   0x7fffe5,  0x3fffd9,  0x7fffe6,   0x7fffe7,   0xffffef,
    0x3fffda,  0x1fffdd,  0xfffe9,    0x3fffdb,  0x3fffdc,  0x7fffe8,   0x7fffe9,   0x1fffde,
    0x7fffea,  0x3fffdd,  0x3fffde,   0xfffff0,  0x1fffdf,  0x3fffdf,   0x7fffeb,   0x7fffec,
    0x1fffe0,  0x1fffe1,  0x3fffe0,   0x1fffe2,  0x7fffed,  0x3fffe1,   0x7fffee,   0x7fffef,
    0xfffea,   0x3fffe2,  0x3fffe3,   0x3fffe4,  0x7ffff0,  0x3fffe5,   0x3fffe6,   0x7ffff1,
    0x3ffffe0, 0x3ffffe1, 0xfffeb,    0x7fff1,   0x3fffe7,  0x7ffff2,   0x3fffe8,   0x1ffffec,
    0x3ffffe2, 0x3ffffe3, 0x3ffffe4,  0x7ffffde, 0x7ffffdf, 0x3ffffe5,  0xfffff1,   0x1ffffed,
    0x7fff2,   0x1fffe3,  0x3ffffe6,  0x7ffffe0, 0x7ffffe1, 0x3ffffe7,  0x7ffffe2,  0xfffff2,
    0x1fffe4,  0x1fffe5,  0x3ffffe8,  0x3ffffe9, 0xffffffd, 0x7ffffe3,  0x7ffffe4,  0x7ffffe5,
    0xfffec,   0xfffff3,  0xfffed,    0x1fffe6,  0x3fffe9,  0x1fffe7,   0x1fffe8,   0x7ffff3,
    0x3fffea,  0x3fffeb,  0x1ffffee,  0x1ffffef, 0xfffff4,  0xfffff5,   0x3ffffea,  0x7ffff4,
    0x3ffffeb, 0x7ffffe6, 0x3ffffec,  0x3ffffed, 0x7ffffe7, 0x7ffffe8,  0x7ffffe9,  0x7ffffea,
    0x7ffffeb, 0xffffffe, 0x7ffffec,  0x7ffffed, 0x7ffffee, 0x7ffffef,  0x7fffff0,  0x3ffffee,
};

const huffman_code_lengths = [_]u8{
    13, 23, 28, 28, 28, 28, 28, 28,
    28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28,
    28, 28, 28, 28, 28, 28, 28, 28,
    6,  10, 10, 12, 13, 6,  8,  11,
    10, 10, 8,  11, 8,  6,  6,  6,
    5,  5,  5,  6,  6,  6,  6,  6,
    6,  6,  7,  8,  15, 6,  12, 10,
    13, 6,  7,  7,  7,  7,  7,  7,
    7,  7,  7,  7,  7,  7,  7,  7,
    7,  7,  7,  7,  7,  7,  7,  7,
    8,  7,  8,  13, 19, 13, 14, 6,
    15, 5,  6,  5,  6,  5,  6,  6,
    6,  5,  7,  7,  6,  6,  6,  5,
    6,  7,  6,  5,  5,  6,  7,  7,
    7,  7,  7,  15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23,
    22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23,
    23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21,
    23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23,
    20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25,
    26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24,
    21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23,
    22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27,
    27, 28, 27, 27, 27, 27, 27, 26,
};

fn decodeHuffman(allocator: Allocator, encoded: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    var code: u32 = 0;
    var code_len: u8 = 0;
    for (encoded) |byte_value| {
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            code = (code << 1) | @as(u32, (byte_value >> @as(u3, @intCast(7 - bit))) & 1);
            code_len += 1;

            if (code_len == 30 and code == 0x3fffffff) return error.InvalidHuffman; // EOS.

            var found = false;
            var symbol: usize = 0;
            while (symbol < huffman_codes.len) : (symbol += 1) {
                if (huffman_code_lengths[symbol] == code_len and huffman_codes[symbol] == code) {
                    if (symbol == 256) return error.InvalidHuffman; // EOS is not a symbol.
                    try output.append(allocator, @intCast(symbol));
                    code = 0;
                    code_len = 0;
                    found = true;
                    break;
                }
            }
            if (!found and code_len > 30) return error.InvalidHuffman;
        }
    }

    // Remaining bits must be a prefix of the all-ones EOS code and at most
    // seven bits long (RFC 7541 section 5.2).
    if (code_len > 7) return error.InvalidHuffman;
    if (code_len > 0) {
        const mask: u32 = (@as(u32, 1) << @as(u5, @intCast(code_len))) - 1;
        if ((code & mask) != mask) return error.InvalidHuffman;
    }
    return output.toOwnedSlice(allocator);
}

test "literal HPACK header" {
    const allocator = std.testing.allocator;
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(allocator);
    try appendLiteralHeader(&block, allocator, ":status", "200");
    var decoder = Decoder.init(allocator);
    defer decoder.deinit();
    var info = HeaderInfo{};
    try decoder.decode(block.items, &info);
    try std.testing.expectEqual(@as(?u16, 200), info.http_status);
}

test "HPACK Huffman strings" {
    const allocator = std.testing.allocator;
    const encoded = [_]u8{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
    const decoded = try decodeHuffman(allocator, &encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("www.example.com", decoded);
}

test "malformed headers and grpc messages do not leak" {
    var decoder = Decoder.init(std.testing.allocator);
    defer decoder.deinit();
    var info = HeaderInfo{};
    // Name allocated, value missing: the error path must release the name.
    try std.testing.expectError(error.Truncated, decoder.decode(&.{ 0, 1, 'x' }, &info));
    try std.testing.expectError(error.Truncated, decoder.decode(&.{ 0x40, 1, 'x' }, &info));
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(std.testing.allocator);
    try appendLiteralHeader(&block, std.testing.allocator, "grpc-message", "rejected");
    try decoder.decode(block.items, &info);
    try std.testing.expectEqualStrings("rejected", info.grpc_message[0..info.grpc_message_len]);
}
