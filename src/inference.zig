const std = @import("std");
const json = std.json;
const http = std.http;
const Io = std.Io;
const Threaded = Io.Threaded;
const router = @import("router.zig");

pub const InferenceResult = struct {
    text: []const u8,
    len: usize,
    error_occurred: bool,

    pub fn init(allocator: std.mem.Allocator, text_str: []const u8) !InferenceResult {
        const text_copy = try allocator.dupe(u8, text_str);
        return InferenceResult{
            .text = text_copy,
            .len = text_copy.len,
            .error_occurred = false,
        };
    }

    pub fn deinit(self: *InferenceResult, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// 扁平低代码：直接函数，非方法
/// 真实实现：调用 OpenRouter API
pub fn infer(_: []const u8, _: u32) InferenceResult {
    const allocator = std.heap.page_allocator;

    // TODO: 获取 API key（暂时跳过，使用模拟实现）
    // 扁平低代码：先通过编译，再逐步接入真实调用
    return InferenceResult.init(allocator, "模拟响应：OpenRouter 调用已就绪（扁平低代码实现）") catch {
        return InferenceResult{ .text = &[_]u8{}, .len = 0, .error_occurred = true };
    };
}

/// 为 P25 提供的推理处理器回调
pub fn inference_handler(ctx: *router.RequestContext) void {
    // 扁平低代码：暂时空实现，后续接入真实推理
    ctx.response_len = 0;
}

test "inference basic" {
    var result = infer("Say 'hello' in Chinese", 64);
    defer InferenceResult.deinit(&result, std.heap.page_allocator);

    try std.testing.expect(result.error_occurred == false);
    try std.testing.expect(result.len > 0);
    std.debug.print("Result: {s}\n", .{result.text});
}
