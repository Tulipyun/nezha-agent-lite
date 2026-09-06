//! Human-readable distribution name, separate from version and architecture.
const std = @import("std");

pub fn value(data: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len <= key.len or line[key.len] != '=' or !std.mem.startsWith(u8, line, key)) continue;
        const text = std.mem.trim(u8, line[key.len + 1 ..], " \t\r\"'");
        if (text.len > 0) return text;
    }
    return null;
}

pub fn name(openwrt_release: []const u8, os_release: []const u8) []const u8 {
    return value(openwrt_release, "DISTRIB_ID") orelse value(os_release, "NAME") orelse
        value(os_release, "ID") orelse "Linux";
}

test "LibWrt snapshot description is not part of the distribution name" {
    const release = "DISTRIB_ID='LibWrt'\nDISTRIB_RELEASE='SNAPSHOT'\nDISTRIB_DESCRIPTION='LibWrt SNAPSHOT r12345-example'\n";
    try std.testing.expectEqualStrings("LibWrt", name(release, ""));
}

test "Linux uses NAME without version or architecture concatenation" {
    try std.testing.expectEqualStrings("Debian GNU/Linux", name("", "PRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"\nNAME=\"Debian GNU/Linux\"\nVERSION_ID=\"12\"\n"));
    try std.testing.expectEqualStrings("Ubuntu", name("", "NAME_EXTRA=wrong\nNAME=\"Ubuntu\"\n"));
    try std.testing.expectEqualStrings("Linux", name("", ""));
}
