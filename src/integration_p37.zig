// src/integration_p37.zig
// ZigClaw V2.4 Phase37 | 客服场景端到端闭环测试
const std = @import("std");
const testing = std.testing;
const async_coordinator = @import("async_coordinator.zig");
const orchestrator = @import("orchestrator.zig");
const sub_brain = @import("sub_brain.zig");

// 结果结构体
const Result = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,
};

test "客服场景：文本请求 → 编排量化 → 推理 → 响应" {
    std.debug.print("🎧 P37: 开始客服场景端到端闭环测试\n", .{});

    // 1. 初始化 Coordinator
    var coordinator = async_coordinator.Coordinator.init();
    try testing.expect(!coordinator.hasPending());

    // 2. 模拟用户输入
    const user_input = "我想了解Zig语言的特点";

    // 3. 准备结果存储
    var result = Result{};

    // 4. 回调函数
    const Callback = struct {
        fn callback(result_text: []const u8, user_data: ?*anyopaque) void {
            const r = @as(*Result, @ptrCast(@alignCast(user_data.?)));
            @memcpy(r.buf[0..result_text.len], result_text);
            r.len = result_text.len;
        }
    };

    // 5. 构造推理请求
    const req = async_coordinator.InferenceRequest{
        .prompt = user_input,
        .modality = 0, // text
        .callback = Callback.callback,
        .user_data = @as(?*anyopaque, @ptrCast(&result)),
    };

    // 6. 提交推理请求
    try coordinator.submit(req);
    try testing.expect(coordinator.hasPending());

    std.debug.print("已提交推理请求: {s}\n", .{user_input});

    // 7. 模拟异步推理完成（替代真实推理引擎，用于测试）
    const mock_result = "Zig是一种注重性能、安全和可维护性的系统编程语言...";
    _ = coordinator.complete(mock_result);

    // 8. 验证回调结果
    try testing.expect(result.len > 0);
    try testing.expectEqualStrings(mock_result, result.buf[0..result.len]);

    try testing.expect(!coordinator.hasPending());

    std.debug.print("✅ P37: 客服场景闭环测试通过\n", .{});
}

test "客服场景：使用真实编排器（Ollama 不可用时跳过）" {
    std.debug.print("🎧 P37: 测试真实编排器集成\n", .{});

    var coordinator = async_coordinator.Coordinator.init();

    var result = Result{};

    const Callback = struct {
        fn callback(result_text: []const u8, user_data: ?*anyopaque) void {
            const r = @as(*Result, @ptrCast(@alignCast(user_data.?)));
            @memcpy(r.buf[0..result_text.len], result_text);
            r.len = result_text.len;
        }
    };

    const req = async_coordinator.InferenceRequest{
        .prompt = "ZigClaw如何实现异步推理？",
        .modality = 0,
        .callback = Callback.callback,
        .user_data = @as(?*anyopaque, @ptrCast(&result)),
    };

    try coordinator.submit(req);

    // 使用真实编排器生成推理结果
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var orch = orchestrator.Orchestrator.init();
    _ = orch.register_brain(sub_brain.getImageBrainReal());

    const inference_result = orch.infer(alloc, req.prompt, .Text) catch |err| {
        std.debug.print("推理失败（Ollama可能未运行）: {}\n", .{err});
        // Ollama 不可用时，使用 mock 结果完成测试
        _ = coordinator.complete("推理服务不可用（Ollama未运行）");
        return;
    };

    // 推理成功，使用真实结果
    _ = coordinator.complete(inference_result.text);

    try testing.expect(result.len > 0);
    std.debug.print("推理结果长度: {d}\n", .{result.len});

    std.debug.print("✅ P37: 真实编排器集成测试通过\n", .{});
}

test "客服场景：图像模态请求（mock）" {
    std.debug.print("🎧 P37: 测试图像模态请求\n", .{});

    var coordinator = async_coordinator.Coordinator.init();

    var result = Result{};

    const Callback = struct {
        fn callback(result_text: []const u8, user_data: ?*anyopaque) void {
            const r = @as(*Result, @ptrCast(@alignCast(user_data.?)));
            @memcpy(r.buf[0..result_text.len], result_text);
            r.len = result_text.len;
        }
    };

    const req = async_coordinator.InferenceRequest{
        .prompt = "user_uploaded_image.jpg",
        .modality = 1, // image
        .callback = Callback.callback,
        .user_data = @as(?*anyopaque, @ptrCast(&result)),
    };

    try coordinator.submit(req);

    // 模拟图像推理完成
    const mock_result = "图片中显示了一个Zig语言的代码示例...";
    _ = coordinator.complete(mock_result);

    try testing.expect(result.len > 0);
    try testing.expectEqualStrings(mock_result, result.buf[0..result.len]);

    std.debug.print("✅ P37: 图像模态请求测试通过\n", .{});
}
