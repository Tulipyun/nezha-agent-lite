//! Host-side protocol soak probe. It never opens RequestTask and therefore
//! never executes work sent by the server. The credential comes only from the
//! NEZHA_TEST_SECRET environment variable.

const std = @import("std");
const probe_env = @import("probe_env.zig");
const h2 = @import("h2.zig");
const proto = @import("proto.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var endpoint = try probe_env.load(allocator);
    defer endpoint.deinit();

    var client = try h2.Client.connect(allocator, endpoint.authority, endpoint.host, endpoint.port, endpoint.secret);
    defer client.deinit();

    const cpus = [_][]const u8{"Zig protocol soak probe 4 Core"};
    const host_payload = try proto.encodeHost(allocator, .{
        .platform = "protocol-test",
        .platform_version = "continuous",
        .cpu = &cpus,
        .mem_total = 512 * 1024 * 1024,
        .disk_total = 128 * 1024 * 1024,
        .arch = "aarch64",
        .boot_time = @intCast(@divFloor(std.time.milliTimestamp(), 1000) - 3600),
        .version = "0.20.5-zig-soak",
    });
    defer allocator.free(host_payload);
    try callAndCheck(allocator, &client, "/proto.NezhaService/ReportSystemInfo", host_payload);
    std.debug.print("host receipt ok\n", .{});

    var index: u64 = 0;
    while (index < 90) : (index += 1) {
        const state_payload = try proto.encodeState(allocator, .{
            .cpu = 10.0 + @as(f64, @floatFromInt(index % 10)),
            .mem_used = (128 + index % 16) * 1024 * 1024,
            .disk_used = 32 * 1024 * 1024,
            .net_in_transfer = 1000000 + index * 4096,
            .net_out_transfer = 500000 + index * 2048,
            .net_in_speed = 4096,
            .net_out_speed = 2048,
            .uptime = 3600 + index,
            .load1 = 0.10,
            .load5 = 0.20,
            .load15 = 0.30,
            .tcp_conn_count = 8,
            .udp_conn_count = 4,
            .process_count = 64,
        });
        defer allocator.free(state_payload);
        try callAndCheck(allocator, &client, "/proto.NezhaService/ReportSystemState", state_payload);
        std.debug.print("state {d}/90 receipt ok\n", .{index + 1});
        std.Thread.sleep(std.time.ns_per_s);
    }
}

fn callAndCheck(allocator: std.mem.Allocator, client: *h2.Client, path: []const u8, payload: []const u8) !void {
    const reply = try client.unary(path, payload);
    defer allocator.free(reply);
    const receipt = try proto.decodeReceipt(reply);
    if (!receipt.proced) return error.ServerRejected;
}
