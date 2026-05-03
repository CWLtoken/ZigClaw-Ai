const std = @import("std");
const testing = std.testing;
const inference = @import("inference.zig");

test "Phase26: 推理集成测试 - 模拟验证" {
    const allocator = testing.allocator;

    // 测试模拟推理接口
    std.debug.print("\n🚀 开始模拟推理测试...\\n", .{});
    var result = try inference.infer(allocator, "用一句话介绍Zig 0.16", 150, "fake-key");
    defer result.deinit(allocator);

    // 校验结果
    try testing.expect(result.len > 0);
    std.debug.print("✅ 测试成功！回复：{s}\\n", .{result.text});
}
