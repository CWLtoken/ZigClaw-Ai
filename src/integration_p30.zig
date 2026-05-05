const std = @import("std");
const testing = std.testing;
const orchestrator = @import("orchestrator.zig");
const token = @import("token.zig");
const inference = @import("inference.zig");

test "Phase30: 编排层集成 - 文本直通 → 模拟推理" {
    const allocator = testing.allocator;
    // 1. 初始化编排器
    var orch = orchestrator.Orchestrator.init();
    try testing.expectEqual(@as(u8, 1), orch.brains_len); // 文本子脑已注册

    // 2. 模拟客服请求（文本输入）
    const user_input = "如何优化ZigClaw性能？";
    var seq = token.TokenSequence.init();

    // 3. 通过编排器获得 Token 序列（文本直通）
    std.debug.print("\n🔄 Phase30: 编排器处理文本输入...\n", .{});
    try orch.orchestrate(user_input, .Text, &seq);
    try testing.expectEqual(@as(u16, 1), seq.len);

    // 4. 验证 Token 正确性
    const tok = seq.get(0).?;
    try testing.expect(tok.tpe == .Text);
    try testing.expectEqualSlices(u8, user_input, tok.getText());
    std.debug.print("✅ Token 生成正确: {s}\n", .{tok.getText()});

    // 5. 模拟调用推理引擎（使用 Token 文本拼接成 prompt）
    var prompt_buf: [512]u8 = undefined;
    const prompt_len = std.fmt.bufPrint(prompt_buf[0..], "用户问题：{s}", .{tok.getText()}) catch "默认问题";
    
    std.debug.print("🚀 调用推理引擎（模拟）...\n", .{});
    var result = try inference.infer(allocator, prompt_len, 150, "fake-key");
    defer result.deinit(allocator);

    try testing.expect(result.len > 0);
    std.debug.print("✅ Phase30 集成测试成功！\n", .{});
}

test "Phase30: 编排层集成 - 图像模态（模拟）" {
    // 1. 初始化编排器并注册图像子脑
    var orch = orchestrator.Orchestrator.init();
    _ = orch.register_brain(@import("sub_brain.zig").getImageBrain());

    // 2. 模拟图像输入
    const image_data = "mock_image_bytes";
    var seq = token.TokenSequence.init();

    // 3. 编排器处理图像（量化路径）
    std.debug.print("\n🔄 Phase30: 编排器处理图像输入（模拟）...\n", .{});
    try orch.orchestrate(image_data, .Image, &seq);
    try testing.expectEqual(@as(u16, 1), seq.len);

    // 4. 验证 Token（应为 VectorQuantized 类型）
    const tok = seq.get(0).?;
    try testing.expect(tok.tpe == .VectorQuantized);
    std.debug.print("✅ 图像 Token 量化成功\n", .{});
}

test "Phase30: 整体链路验证 - 文本直通 + 推理 + 响应" {
    const allocator = testing.allocator;

    // 完整流程：输入 → 编排 → 推理 → 输出
    var orch = orchestrator.Orchestrator.init();
    const input = "Zig 0.16 有哪些新特性？";
    var seq = token.TokenSequence.init();

    try orch.orchestrate(input, .Text, &seq);
    // 拼接 prompt（从 TokenSequence 提取所有文本）
    var full_prompt: [1024]u8 = undefined;
    var prompt_len: usize = 0;
    var i: u16 = 0;
    while (i < seq.len) : (i += 1) {
        const t = seq.get(i).?;
        if (t.tpe == .Text) {
            const text = t.getText();
            std.mem.copyForwards(u8, full_prompt[prompt_len..], text);
            prompt_len += text.len;
        }
    }

    // 调用推理
    var result = try inference.infer(allocator, full_prompt[0..prompt_len], 200, "test-key");
    defer result.deinit(allocator);

    try testing.expect(result.len > 0);
    std.debug.print("✅ Phase30 全链路验证成功！推理结果: {s}\n", .{result.text});
}
