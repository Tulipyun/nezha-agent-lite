const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "nezha-agent-lite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = true,
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the agent");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| run_cmd.addArgs(args);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    });
    const test_step = b.step("test", "Run portable protocol, queue, configuration and ICMP packet tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    const probe = b.addExecutable(.{
        .name = "protocol-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocol_probe.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    });
    const probe_step = b.step("probe", "Build the local integration-test client");
    probe_step.dependOn(&b.addInstallArtifact(probe, .{}).step);

    const metrics = b.addExecutable(.{
        .name = "metrics-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/metrics_probe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = true,
        }),
    });
    const metrics_step = b.step("metrics-probe", "Build the Linux metrics verification utility");
    metrics_step.dependOn(&b.addInstallArtifact(metrics, .{}).step);
}
