const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build the agent runtime static library
    const lib = b.addStaticLibrary(.{
        .name = "agent_rt",
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Optional: Add a test executable
    const exe = b.addExecutable(.{
        .name = "agent_test",
        .root_source_file = b.path("src/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

    // Test step
    const test_step = b.step("test", "Run library tests");
    const lib_tests = b.addTest(.{
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_step.dependOn(&lib_tests.step);
}
