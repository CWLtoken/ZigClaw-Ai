// build.zig
// ZigClaw V2.4 | 蒸汽机风格构建系统 | Zig 0.16 显性装配
const std = @import("std");

pub fn build(b: *std.Build) void {
    // 添加自定义 test 步骤：直接调用 zig test
    const test_step = b.step("test", "Run ZigClaw Phase 3-5 Integration Tests");
    const zig_exe = b.findProgram(&.{"zig"}, &.{}) catch unreachable;
    const test_cmd = b.addSystemCommand(&.{
        zig_exe,
        "test",
        "src/tests.zig",
        "-ODebug",
    });
    test_step.dependOn(&test_cmd.step);
}
