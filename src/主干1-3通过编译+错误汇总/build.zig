// build.zig
// ZigClaw V2.4 | 蒸汽机风格构建系统 | Zig 0.16 显性装配
const std = @import("std");

pub fn build(b: *std.Build) void {
    // 1. 标准配置
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 2. 锻造测试模块：target/optimize 必须放在这里
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 3. 安装测试齿轮：TestOptions 只接收 root_module
    const test_runner = b.addTest(.{
        .root_module = test_mod,
    });

    // 4. 注册测试步骤：取 Run 的 step 指针，传给 dependOn
    const run_test = b.addRunArtifact(test_runner);
    const test_step = b.step("test", "Run ZigClaw Phase 3-5 Integration Tests");
    test_step.dependOn(&run_test.step);
}