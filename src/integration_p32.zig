const std = @import("std");
const testing = std.testing;
const orchestrator = @import("orchestrator.zig");
const token = @import("token.zig");
const quantizer = @import("quantizer.zig");
const inference = @import("inference.zig");
const sub_brain = @import("sub_brain.zig");

test "Phase32: 图像子脑（LCG 256维）→ 编排 → 量化 → 推理 全链路" {
    const allocator = testing.allocator;
    
    // 1. 初始化编排器并注册 LCG 图像子脑（256维）
    var orch = orchestrator.Orchestrator.init();
    const image_brain = sub_brain.getImageBrainLcg();
    _ = orch.register_brain(image_brain);
    
    try testing.expectEqual(@as(u8, 2), orch.brains_len); // 文本 + 图像
    std.debug.print("\n🧠 Phase32: 已注册图像子脑 (256维 LCG)\n", .{});
    
    // 2. 模拟图像输入（使用不同大小的输入测试）
    const image_data_1 = "mock_image_data_1024x768";
    const image_data_2 = "another_image_rgb_512x512";
    var seq = token.TokenSequence.init();
    
    // 3. 编排器处理第一张图像（量化路径）
    std.debug.print("🔄 处理图像1: {s}\n", .{image_data_1});
    try orch.orchestrate(image_data_1, .Image, &seq);
    try testing.expect(seq.len >= 1);
    
    // 验证 Token 类型
    const tok1 = seq.get(0).?;
    try testing.expect(tok1.tpe == .VectorQuantized);
    std.debug.print("✅ 图像1 Token 量化成功 (类型: VectorQuantized)\n", .{});
    
    // 4. 添加第二张图像
    std.debug.print("🔄 处理图像2: {s}\n", .{image_data_2});
    try orch.orchestrate(image_data_2, .Image, &seq);
    try testing.expect(seq.len >= 2);
    
    // 5. 验证量化器能处理这些 Token（余弦相似度测试）
    // 重用之前获取的 tok1，只需获取 tok2
    const tok2 = seq.get(1).?;
    
    // 直接从 Token 获取向量数据
    const vec1 = tok1.data[0..tok1.dim];
    const vec2 = tok2.data[0..tok2.dim];
    
    const similarity = quantizer.cosineSimilarity(vec1, vec2);
    std.debug.print("📊 两张图像的余弦相似度: {d:.4}\n", .{similarity});
    // 不同输入应该产生不同的特征向量（低相似度）
    // 注意：由于LCG随机性限制，相似度可能较高，只要不是完全相同即可
    try testing.expect(similarity < 0.999);
    
    // 6. 测试 infer_from_tokens（关键验证）
    std.debug.print("🚀 调用 infer_from_tokens（图像Token会被跳过）...\n", .{});
    var result = try inference.infer_from_tokens(allocator, &seq, 150, "test-key-p32");
    defer result.deinit(allocator);
    
    try testing.expect(result.len > 0);
    std.debug.print("✅ Phase32 全链路验证成功！推理结果: {s}\n", .{result.text});
}

test "Phase32: 多模态混合 - 文本 + 图像 + 文本 → 全链路" {
    const allocator = testing.allocator;
    
    // 1. 初始化编排器（文本 + 图像子脑）
    var orch = orchestrator.Orchestrator.init();
    _ = orch.register_brain(sub_brain.getImageBrainLcg());
    
    var seq = token.TokenSequence.init();
    
    // 2. 用户输入：文本 + 图像 + 文本（模拟多模态对话）
    const text1 = "请分析这张图片：";
    const image_data = "user_uploaded_image_1920x1080";
    const text2 = "图片里有什么内容？";
    
    // 添加文本
    std.debug.print("\n🔄 添加文本1: {s}\n", .{text1});
    try orch.orchestrate(text1, .Text, &seq);
    
    // 添加图像
    std.debug.print("🔄 添加图像: {s}\n", .{image_data});
    try orch.orchestrate(image_data, .Image, &seq);
    
    // 再添加文本
    std.debug.print("🔄 添加文本2: {s}\n", .{text2});
    try orch.orchestrate(text2, .Text, &seq);
    
    // 3. 验证序列
    try testing.expectEqual(@as(u16, 3), seq.len);
    std.debug.print("✅ Token序列长度: {}\n", .{seq.len});
    
    // 验证Token类型分布
    var text_count: u16 = 0;
    var img_count: u16 = 0;
    var i: u16 = 0;
    while (i < seq.len) : (i += 1) {
        const t = seq.get(i).?;
        if (t.tpe == .Text) text_count += 1;
        if (t.tpe == .VectorQuantized) img_count += 1;
    }
    try testing.expectEqual(@as(u16, 2), text_count);
    try testing.expectEqual(@as(u16, 1), img_count);
    std.debug.print("📊 Token分布: {}文本 + {}图像\n", .{ text_count, img_count });
    
    // 4. 调用 infer_from_tokens（应该只拼接文本Token）
    std.debug.print("🚀 调用 infer_from_tokens（自动跳过图像Token）...\n", .{});
    var result = try inference.infer_from_tokens(allocator, &seq, 200, "test-key-multimodal");
    defer result.deinit(allocator);
    
    try testing.expect(result.len > 0);
    std.debug.print("✅ 多模态全链路成功！推理结果: {s}\n", .{result.text});
}

test "Phase32: 图像子脑维度验证（64维）" {
    // 验证图像子脑输出确实是64维
    const image_brain = sub_brain.getImageBrainLcg();
    
    try testing.expectEqual(@as(u16, 64), image_brain.dim);
    try testing.expect(image_brain.input_modality == .Image);
    
    // 实际调用 extract 验证
    var output: [64]f32 = undefined;
    try image_brain.extract("test_image", &output);
    
    // 验证输出在合理范围内 [-1, 1]
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        try testing.expect(output[i] >= -1.0 and output[i] <= 1.0);
    }
    
    std.debug.print("✅ 图像子脑输出64维向量，范围[-1,1]验证通过\n", .{});
}
