// build.zig
// ZigClaw-AI v3.1 | 军规级构建系统 | Zig 0.16 标准 Build API
const Build = @import("std").Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -------------------------------------------------
    // 0. 编译期配置选项
    // -------------------------------------------------
    const batch_threshold = b.option(u32, "batch_threshold", "io_uring SQE batch submit threshold (default: 8)") orelse 8;
    const build_options = b.addOptions();
    build_options.addOption(u32, "batch_threshold", batch_threshold);

    // -------------------------------------------------
    // 1. C 库：image_feature（stb_image 实现，零第三方依赖）
    // 军规：使用 addLibrary + addCSourceFile，禁止 addSystemCommand
    // -------------------------------------------------
    const c_mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
    });
    c_mod.addCSourceFile(.{
        .file = b.path("src/image_feature.c"),
        .flags = &.{"-std=c11"},
    });
    c_mod.linkSystemLibrary("c", .{});

    const c_lib = b.addLibrary(.{
        .name = "image_feature",
        .root_module = c_mod,
    });

    // -------------------------------------------------
    // 2. 主可执行文件：ZigClaw 服务
    // -------------------------------------------------
    const use_mt = b.option(bool, "mt", "Enable multi-threaded HTTP server") orelse false;
    const main_src = if (use_mt) "src/main_mt.zig" else "src/main.zig";

    const exe_mod = b.createModule(.{
        .root_source_file = b.path(main_src),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "zigclaw",
        .root_module = exe_mod,
    });
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.linkLibrary(c_lib);
    exe.root_module.link_libc = true;

    // -------------------------------------------------
    // 3. 测试：集成测试
    // -------------------------------------------------
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    tests.root_module.addOptions("build_options", build_options);
    tests.root_module.linkLibrary(c_lib);
    tests.root_module.link_libc = true;

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
    b.default_step = &exe.step;
}
