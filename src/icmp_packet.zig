//! Packet matching is shared by the Linux implementation and portable tests.
const std = @import("std");
pub const packet_size = 24;
const magic = "nezha-zg";

pub fn request(packet: *[packet_size]u8, ipv6: bool, identifier: u16, sequence: u16, nonce: u64) void {
    @memset(packet, 0);
    packet[0] = if (ipv6) 128 else 8;
    std.mem.writeInt(u16, packet[4..6], identifier, .big);
    std.mem.writeInt(u16, packet[6..8], sequence, .big);
    @memcpy(packet[8..16], magic);
    std.mem.writeInt(u64, packet[16..24], nonce, .big);
    if (!ipv6) std.mem.writeInt(u16, packet[2..4], checksum(packet), .big);
}

pub fn checksum(data: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) sum += (@as(u32, data[i]) << 8) | data[i + 1];
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

pub fn matches(data: []const u8, ipv6: bool, identifier: u16, sequence: u16, nonce: u64, check_identifier: bool) bool {
    var offset: usize = 0;
    if (data.len == 0) return false;
    if (!ipv6 and data[0] >> 4 == 4) {
        offset = @as(usize, data[0] & 0x0f) * 4;
        if (offset < 20) return false;
    } else if (ipv6 and data[0] >> 4 == 6) offset = 40;
    if (data.len < offset + packet_size) return false;
    const message = data[offset..];
    if (message[0] != (if (ipv6) @as(u8, 129) else 0) or message[1] != 0) return false;
    if (check_identifier and std.mem.readInt(u16, message[4..6], .big) != identifier) return false;
    return std.mem.readInt(u16, message[6..8], .big) == sequence and
        std.mem.eql(u8, message[8..16], magic) and
        std.mem.readInt(u64, message[16..24], .big) == nonce;
}

test "checksum and matching distinguish concurrent probes of the same host" {
    var packet: [packet_size]u8 = undefined;
    request(&packet, false, 10, 1, 123);
    try std.testing.expectEqual(@as(u16, 0), checksum(&packet));
    packet[0] = 0;
    try std.testing.expect(matches(&packet, false, 10, 1, 123, true));
    try std.testing.expect(!matches(&packet, false, 10, 1, 124, true));
    try std.testing.expect(!matches(&packet, false, 11, 1, 123, true));
    try std.testing.expect(!matches(&packet, false, 10, 2, 123, true));
    try std.testing.expect(matches(&packet, false, 99, 1, 123, false));
    try std.testing.expect(!matches(packet[0..8], false, 10, 1, 123, false));
}

test "IPv6 and IPv4 raw headers are handled" {
    var packet: [packet_size]u8 = undefined;
    request(&packet, true, 10, 1, 321);
    packet[0] = 129;
    try std.testing.expect(matches(&packet, true, 10, 1, 321, true));
    request(&packet, false, 10, 1, 321);
    packet[0] = 0;
    var raw: [20 + packet_size]u8 = @splat(0);
    raw[0] = 0x45;
    @memcpy(raw[20..], &packet);
    try std.testing.expect(matches(&raw, false, 10, 1, 321, true));
    raw[0] = 0x41;
    try std.testing.expect(!matches(&raw, false, 10, 1, 321, true));
}
