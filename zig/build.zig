const std = @import("std");

pub fn build(b: *std.Build) void {
    // Zig build configuration for agent runtime
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    
    // Placeholder for agent runtime library
    const lib = b.addStaticLibrary(.{
        .name = "agent_rt",
        .root_source_file = b.path("src/agent.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);
}
