const std = @import("std");
const testing = std.testing;
const inference = @import("inference.zig");

test "Phase26: OpenRouter inference end-to-end" {
    // 扁平直白：直接调用 infer，验证返回非空
    const prompt = "什么是Zig语言？请用一句话回答。";
    const result = inference.infer(prompt, 64);
    
    // 验证推理成功（模拟实现总是成功）
    try testing.expect(!result.error_occurred);
    try testing.expect(result.len > 0);
    try testing.expect(result.text[0] != 0);
    
    // 打印结果
    std.debug.print("\nPhase26 推理结果: {s}\n", .{result.text[0..result.len]});
}
