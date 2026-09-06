//! Read-only Linux metrics check, with no dashboard connection.
const std = @import("std");
const monitor_mod = @import("monitor.zig");

pub fn main() !void {
    var monitor = monitor_mod.Monitor.init(std.heap.page_allocator);
    const host = monitor.host();
    const state = monitor.state();
    std.debug.print("platform={s}\nplatform_version={s}\narch={s}\ndisk_total_bytes={d}\ndisk_used_bytes={d}\nmem_total_bytes={d}\nmem_used_bytes={d}\n", .{
        host.platform, host.platform_version, host.arch, host.disk_total, state.disk_used, host.mem_total, state.mem_used,
    });
}
