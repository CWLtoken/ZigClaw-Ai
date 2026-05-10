const mem = @import("std").mem;
const inference = @import("inference.zig");

test "P34: 端到端推理验证（Ollama）" {
    const testing = @import("std").testing;
    const allocator = testing.allocator;

    @import("std").log.info("开始 P34 测试（如果 Ollama 未运行将跳过）", .{});

    // 调用推理函数
    const test_prompt = "什么是Zig语言？";
    const result = try inference.infer(allocator, test_prompt, 100, "");
    defer {
        var mutable_result = result; // 复制一份可变副本
        mutable_result.deinit(allocator);
    }

    // 检查是否是错误信息（Ollama 未运行）
    if (mem.startsWith(u8, result.text, "推理服务不可用")) {
        @import("std").log.warn("Ollama 未运行或推理失败，跳过 P34 测试。错误信息: {s}", .{result.text[0..@min(100, result.len)]});
        return; // 直接返回，测试通过（跳过）
    }

    // 验证推理结果
    try testing.expect(result.len > 0);
    try testing.expect(result.text.len > 0);

    // 打印推理结果（前200字符）
    const display_len = @min(200, result.len);
    @import("std").log.info("P34 推理结果: {s}", .{result.text[0..display_len]});

    // 验证响应包含有效内容（非空且不是错误信息）
    try testing.expect(!mem.eql(u8, result.text, ""));

    // 检查是否包含中文（简单判断：包含中文字符）
    var has_chinese = false;
    for (result.text) |ch| {
        if (ch > 0x4E00 and ch < 0x9FFF) { // 简单的中文字符范围
            has_chinese = true;
            break;
        }
    }
    try testing.expect(has_chinese); // 推理结果应该包含中文

    @import("std").log.info("P34 端到端测试通过 ✅", .{});
}
