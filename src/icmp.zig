const builtin = @import("builtin");

pub const Result = struct {
    successful: bool = false,
    delay_ms: f32 = 0,
    received: u32 = 0,
    message: []const u8 = "",
};

pub const ping = if (builtin.os.tag == .linux)
    @import("icmp_linux.zig").ping
else
    @import("icmp_stub.zig").ping;

pub const pingWithTimeout = if (builtin.os.tag == .linux)
    @import("icmp_linux.zig").pingWithTimeout
else
    @import("icmp_stub.zig").pingWithTimeout;
