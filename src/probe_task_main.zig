const std = @import("std");
const probe_env = @import("probe_env.zig");
const h2 = @import("h2.zig");
const proto = @import("proto.zig");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var endpoint = try probe_env.load(allocator);
    defer endpoint.deinit();
    const host_bytes = try proto.encodeHost(allocator, .{ .arch = "aarch64", .version = "0.20.5-zig-probe" });
    defer allocator.free(host_bytes);

    var task_client = try h2.Client.connect(allocator, endpoint.authority, endpoint.host, endpoint.port, endpoint.secret);
    defer task_client.deinit();
    var tasks = try task_client.openTaskStream(host_bytes);
    defer tasks.deinit();
    const task = (try tasks.next()) orelse return error.NoTask;
    std.debug.print("received task id={} type={} data={s}\n", .{ task.id, task.type, task.data });

    const result_bytes = try proto.encodeTaskResult(allocator, .{
        .id = task.id,
        .type = task.type,
        .data = "zig probe: task intentionally not executed",
        .successful = false,
    });
    defer allocator.free(result_bytes);

    var report_client = try h2.Client.connect(allocator, endpoint.authority, endpoint.host, endpoint.port, endpoint.secret);
    defer report_client.deinit();
    const receipt_bytes = try report_client.unary("/proto.NezhaService/ReportTask", result_bytes);
    defer allocator.free(receipt_bytes);
    const receipt = try proto.decodeReceipt(receipt_bytes);
    std.debug.print("ReportTask proced={}\n", .{receipt.proced});
}
