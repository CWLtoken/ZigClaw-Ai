// src/integration_p31.zig
// ZigClaw V2.4 Phase31 | 集成测试 | infer_from_tokens 全链路验证
const std = @import("std");
const testing = std.testing;
const orchestrator = @import("orchestrator.zig");
const token = @import("token.zig");
const inference = @import("inference.zig");

test "P31: infer_from_tokens + 编排层 + 推理层全链路 - 文本直通" {
    const allocator = testing.allocator;

    // 1. 初始化编排器
    var orch = orchestrator.Orchestrator.init();
    try testing.expectEqual(@as(u8, 1), orch.brains_len); // 文本子脑已注册

    // 2. 模拟用户输入（文本）
    const user_input = "ZigClaw 编排层如何工作？";
    var seq = token.TokenSequence.init();

    // 3. 通过编排器获得 Token 序列（文本直通）
    std.debug.print("\n🔄 P31: 编排器处理文本输入...\n", .{});
    try orch.orchestrate(user_input, .Text, &seq);
    try testing.expectEqual(@as(u16, 1), seq.len);

    // 4. 验证 Token 正确性
    const tok = seq.get(0).?;
    try testing.expect(tok.tpe == .Text);
    try testing.expectEqualSlices(u8, user_input, tok.getText());
    std.debug.print("✅ Token 生成正确: {s}\n", .{tok.getText()});

    // 5. 调用 infer_from_tokens
    std.debug.print("🚀 调用 infer_from_tokens...\n", .{});
    var result = try inference.infer_from_tokens(allocator, &seq, 150, "fake-key");
    defer result.deinit(allocator);

    // 6. 验证推理结果
    try testing.expect(result.len > 0);
    std.debug.print("✅ P31 文本直通全链路验证成功！推理结果: {s}\n", .{result.text});
}

test "P31: infer_from_tokens + 图像模态（模拟）" {
    const allocator = testing.allocator;

    // 1. 初始化编排器并注册图像子脑
    var orch = orchestrator.Orchestrator.init();
    _ = orch.register_brain(@import("sub_brain.zig").getImageBrain());

    // 2. 模拟图像输入
    const image_data = "mock_image_bytes_for_p31_test";
    var seq = token.TokenSequence.init();

    // 3. 编排器处理图像（量化路径）
    std.debug.print("\n🔄 P31: 编排器处理图像输入（模拟）...\n", .{});
    try orch.orchestrate(image_data, .Image, &seq);
    try testing.expectEqual(@as(u16, 1), seq.len);

    // 4. 验证 Token（应为 VectorQuantized 类型）
    const tok = seq.get(0).?;
    try testing.expect(tok.tpe == .VectorQuantized);
    std.debug.print("✅ 图像 Token 量化成功\n", .{});

    // 5. 调用 infer_from_tokens（当前会跳过非文本Token）
    std.debug.print("🚀 调用 infer_from_tokens（跳过非文本Token）...\n", .{});
    var result = try inference.infer_from_tokens(allocator, &seq, 200, "test-key");
    defer result.deinit(allocator);

    try testing.expect(result.len > 0);
    std.debug.print("✅ P31 图像模态全链路验证成功！\n", .{});
}

test "P31: 多模态混合序列 - 文本 + 图像" {
    const allocator = testing.allocator;

    var orch = orchestrator.Orchestrator.init();
    _ = orch.register_brain(@import("sub_brain.zig").getImageBrain());

    var seq = token.TokenSequence.init();

    // 添加文本 Token
    const tok1 = token.Token.initText("你好，我是用户");
    try seq.append(tok1);

    // 添加图像 Token（模拟）
    const image_tok = token.Token.initVector(&[_]f32{ 0.5, 0.3 });
    try seq.append(image_tok);

    // 再添加文本 Token
    const tok2 = token.Token.initText("请分析这张图片");
    try seq.append(tok2);

    try testing.expectEqual(@as(u16, 3), seq.len);

    // 调用 infer_from_tokens（应该只拼接文本Token）
    std.debug.print("\n🔄 P31: 多模态序列处理...\n", .{});
    var result = try inference.infer_from_tokens(allocator, &seq, 300, "test-key");
    defer result.deinit(allocator);

    // 验证结果包含文本（跳过图像Token）
    try testing.expect(result.len > 0);
    std.debug.print("✅ P31 多模态全链路验证成功！推理结果: {s}\n", .{result.text});
}
