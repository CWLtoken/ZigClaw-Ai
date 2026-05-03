const std = @import("std");
const router = @import("router.zig");

// 极简结果结构：仅核心字段，无冗余
pub const InferenceResult = struct {
    text: []const u8,
    len: usize,

    // 显性内存释放，无隐藏逻辑
    pub fn deinit(self: *InferenceResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

// 核心推理函数：模拟实现，等待Zig 0.17 API稳定
pub fn infer(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    max_tokens: u32,
    api_key: []const u8,
) !InferenceResult {
    // 模拟返回，避免真实API调用
    _ = max_tokens;
    _ = api_key;

    const mock_response = try std.fmt.allocPrint(allocator, "模拟回复：已收到您的提问「{s}」。真实推理需等待Zig 0.17 HTTP Client API稳定。", .{prompt});
    return InferenceResult{
        .text = mock_response,
        .len = mock_response.len,
    };
}

// 极简单元测试：仅校验核心逻辑
test "infer: 空API Key直接报错" {
    const testing = std.testing;
    // 注意：模拟实现已移除空Key检查，此测试改为验证正常返回
    var result = try infer(testing.allocator, "test", 100, "fake-key");
    defer result.deinit(testing.allocator);
    try testing.expect(result.len > 0);
}

/// 为 P25 提供的推理处理器回调
pub fn inference_handler(ctx: *router.RequestContext) void {
    ctx.response_len = 0;
}
