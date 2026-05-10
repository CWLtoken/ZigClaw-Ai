const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------
    // 1. C 库：image_feature（stb_image 实现，零第三方依赖）
    // -------------------------------------------------
    const c_src = b.addSystemCommand(&.{
        "zig",
        "build-exe",
        "src/image_feature.c",
        "--library",
        "c",
    });
    _ = c_src;

    // -------------------------------------------------
    // 2. 主可执行文件：ZigClaw 服务
    // -------------------------------------------------
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "zigclaw",
        .root_module = exe_mod,
    });
    exe.linkLibC();

    // -------------------------------------------------
    // 3. 测试：集成测试（P3–P58 等）
    // -------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    tests.linkLibC();

    const test_step = b.step("test", "Run ZigClaw integration tests");
    test_step.dependOn(&tests.step);

    // -------------------------------------------------
    // 4. 运行步骤：zig build run [-- args...]
    // -------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_cmd.setEnvironmentVariable("ZIGCLAW_PORT", b.option([]const u8, "port", "Server port") orelse "8080");
    run_cmd.setEnvironmentVariable("METRICS_PORT", b.option([]const u8, "metrics-port", "Metrics port") orelse "9090");
    run_cmd.setEnvironmentVariable("API_KEY", b.option([]const u8, "api-key", "API key") orelse "dev-key");
    run_cmd.setEnvironmentVariable("OLLAMA_URL", b.option([]const u8, "ollama-url", "Ollama URL") orelse "http://localhost:11434");

    const run_step = b.step("run", "Build and run ZigClaw server");
    run_step.dependOn(&run_cmd.step);

    // -------------------------------------------------
    // 5. 安装步骤
    // -------------------------------------------------
    b.getInstallStep().dependOn(&exe.step);
    b.default_step = exe.step;
}
