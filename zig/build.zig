const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build agent runtime static library
    const lib = b.addStaticLibrary(.{
        .name = "agent_rt",
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    // Verify with nm
    const verify_step = b.step("verify", "Verify exported symbols");
    const verify_cmd = b.addSystemCommand(&.{ "nm", "-g", lib.getOutputLibPath() });
    verify_step.dependOn(&verify_cmd.step);
}
