const std = @import("std");
const testing = std.testing;
const inference = @import("inference.zig");

test "Phase26: OpenRouter inference end-to-end" {
    // 如果 API Key 未配置，跳过测试
    if (inference.OPENROUTER_API_KEY.len == 0) {
        return error.SkipZigTest;
    }

    const prompt = "什么是Zig语言？请用一句话回答。";
    const result = inference.infer(prompt, 64);

    // 验证推理成功
    try testing.expect(!result.error_occurred);
    try testing.expect(result.len > 0);
    // 验证返回内容非空
    try testing.expect(result.text[0] != 0);
}
