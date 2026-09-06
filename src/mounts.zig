//! v0.20.5 default disk selection: expected filesystems, one mount per device.
const std = @import("std");
pub const Usage = struct { total: u64 = 0, used: u64 = 0 };
const Entry = struct { device: []const u8, path: []const u8, filesystem: []const u8 };

fn entry(line: []const u8) ?Entry {
    var fields = std.mem.tokenizeAny(u8, line, " \t\r");
    for (0..4) |_| _ = fields.next() orelse return null;
    const path = fields.next() orelse return null;
    while (fields.next()) |field| {
        if (std.mem.eql(u8, field, "-")) {
            const filesystem = fields.next() orelse return null;
            const device = fields.next() orelse return null;
            return .{ .device = device, .path = path, .filesystem = filesystem };
        }
    }
    return null;
}

fn eligible(item: Entry) bool {
    if (std.mem.indexOf(u8, item.path, "/var/lib/kubelet") != null) return false;
    var buffer: [128]u8 = undefined;
    if (item.filesystem.len > buffer.len) return false;
    for (item.filesystem, 0..) |c, i| buffer[i] = std.ascii.toLower(c);
    const filesystem = buffer[0..item.filesystem.len];
    // Copied from the original agent's expectDiskFsTypes. Its ContainsStr
    // helper performs substring matching, rather than equality.
    for ([_][]const u8{
        "apfs",    "ext4", "ext3",  "ext2", "f2fs",  "reiserfs", "jfs", "btrfs",
        "fuseblk", "zfs",  "simfs", "ntfs", "fat32", "exfat",    "xfs", "fuse.rclone",
    }) |fs| {
        if (std.mem.indexOf(u8, filesystem, fs) != null) return true;
    }
    return false;
}

fn decodePath(encoded: []const u8, output: []u8) ![:0]const u8 {
    var source: usize = 0;
    var used: usize = 0;
    while (source < encoded.len) {
        if (used + 1 >= output.len) return error.PathTooLong;
        var byte = encoded[source];
        source += 1;
        if (byte == '\\') {
            if (encoded.len - source < 3) return error.InvalidEscape;
            var octal: u16 = 0;
            for (encoded[source .. source + 3]) |digit| {
                if (digit < '0' or digit > '7') return error.InvalidEscape;
                octal = octal * 8 + digit - '0';
            }
            if (octal == 0 or octal > 255) return error.InvalidEscape;
            byte = @intCast(octal);
            source += 3;
        }
        if (byte == 0) return error.InvalidEscape;
        output[used] = byte;
        used += 1;
    }
    output[used] = 0;
    return output[0..used :0];
}

pub fn collect(data: []const u8, allocator: std.mem.Allocator, context: anytype, comptime usageAt: anytype) !Usage {
    var devices = std.StringHashMap(void).init(allocator);
    defer devices.deinit();
    var result = Usage{};
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const mount = entry(line) orelse continue;
        if (!eligible(mount) or devices.contains(mount.device)) continue;
        var path_buffer: [4096]u8 = undefined;
        const path = decodePath(mount.path, &path_buffer) catch continue;
        const usage = usageAt(context, path) orelse continue;
        try devices.put(mount.device, {});
        result.total +|= usage.total;
        result.used +|= usage.used;
    }
    return result;
}

test "OpenWrt adds the data partition and does not double count overlay or bind mounts" {
    const Fixture = struct {
        calls: usize = 0,
        fn usage(self: *@This(), path: [:0]const u8) ?Usage {
            self.calls += 1;
            if (std.mem.eql(u8, path, "/overlay")) return .{ .total = 2 * 1024 * 1024 * 1024, .used = 128 * 1024 * 1024 };
            if (std.mem.eql(u8, path, "/mnt/mmcblk0p3")) return .{ .total = 100 * 1024 * 1024 * 1024, .used = 64 * 1024 * 1024 * 1024 };
            return null;
        }
    };
    const data =
        "12 22 179:1 / /rom ro - squashfs /dev/root ro\n" ++
        "18 22 0:18 / /tmp rw - tmpfs tmpfs rw\n" ++
        "19 22 7:0 / /overlay rw - f2fs /dev/loop0 rw\n" ++
        "22 1 0:19 / / rw - overlay overlayfs:/overlay rw\n" ++
        "26 22 179:3 / /mnt/mmcblk0p3 rw - ext4 /dev/mmcblk0p3 rw\n" ++
        "27 22 179:3 / /mnt/data-bind rw - ext4 /dev/mmcblk0p3 rw\n";
    var fixture = Fixture{};
    const result = try collect(data, std.testing.allocator, &fixture, Fixture.usage);
    try std.testing.expectEqual(@as(u64, 102 * 1024 * 1024 * 1024), result.total);
    try std.testing.expectEqual(@as(u64, (64 * 1024 + 128) * 1024 * 1024), result.used);
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "escaped mount paths work and kubelet mounts are excluded" {
    const Fixture = struct {
        fn usage(_: void, path: [:0]const u8) ?Usage {
            if (std.mem.eql(u8, path, "/mnt/USB Drive")) return .{ .total = 1000, .used = 250 };
            return null;
        }
    };
    const data =
        "1 0 8:1 / /var/lib/kubelet/pods rw - ext4 /dev/a rw\n" ++
        "2 0 8:2 / /mnt/USB\\040Drive rw - EXT4 /dev/b rw\n";
    const result = try collect(data, std.testing.allocator, {}, Fixture.usage);
    try std.testing.expectEqual(@as(u64, 1000), result.total);
    try std.testing.expectEqual(@as(u64, 250), result.used);
}
