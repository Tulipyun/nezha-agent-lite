//! Opt-in endpoint configuration for the legacy manual protocol probes.
const std = @import("std");
pub const Endpoint = struct {
    allocator: std.mem.Allocator,
    host: []u8,
    authority: []u8,
    port: u16,
    secret: []u8,

    pub fn deinit(self: *Endpoint) void {
        self.allocator.free(self.host);
        self.allocator.free(self.authority);
        self.allocator.free(self.secret);
    }
};

pub fn load(allocator: std.mem.Allocator) !Endpoint {
    const host = try std.process.getEnvVarOwned(allocator, "NEZHA_TEST_HOST");
    errdefer allocator.free(host);
    if (host.len == 0) return error.MissingServer;
    const port_text = try std.process.getEnvVarOwned(allocator, "NEZHA_TEST_PORT");
    defer allocator.free(port_text);
    const port = std.fmt.parseInt(u16, port_text, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    const secret = try std.process.getEnvVarOwned(allocator, "NEZHA_TEST_SECRET");
    errdefer allocator.free(secret);
    if (secret.len == 0) return error.MissingSecret;
    const authority = if (std.mem.indexOfScalar(u8, host, ':') != null)
        try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host, port })
    else
        try std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
    return .{ .allocator = allocator, .host = host, .port = port, .secret = secret, .authority = authority };
}
