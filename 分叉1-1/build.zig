const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const integration_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_p1.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_integration_test = b.addRunArtifact(integration_test);
    const test_step = b.step("test", "Run Phase 1 Integration Tests");
    test_step.dependOn(&run_integration_test.step);

    const exe = b.addExecutable(.{
        .name = "ZigClaw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);
}