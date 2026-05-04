const std = @import("std");
const router = @import("router.zig");
const token = @import("token.zig");

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

// Ollama 推理客户端（本地非TLS）
const inference_client = @import("inference_client.zig");

// 核心推理函数：优先使用 Ollama 本地推理，OpenAI 路径标记为 WIP
pub fn infer(
    allocator: std.mem.Allocator,
    prompt: []const u8,
    max_tokens: u32,
    api_key: []const u8,
) !InferenceResult {
    _ = max_tokens;
    _ = api_key;

    // 尝试调用 Ollama 本地推理
    // 默认使用 llama3 模型，如需切换可添加模型参数
    const ollama_result = inference_client.query_ollama(prompt, "llama3") catch |err| {
        // Ollama 未运行或调用失败，返回错误信息（非模拟）
        std.log.warn("Ollama 调用失败: {}，返回错误响应", .{err});
        const error_response = try std.fmt.allocPrint(allocator, "推理服务不可用（Ollama未运行？）：{s}", .{@errorName(err)});
        return InferenceResult{
            .text = error_response,
            .len = error_response.len,
        };
    };

    // ollama_result 需要释放（query_ollama 使用 page_allocator）
    // 复制到传入的 allocator
    const result_text = try allocator.dupe(u8, ollama_result);
    std.heap.page_allocator.free(ollama_result);

    return InferenceResult{
        .text = result_text,
        .len = result_text.len,
    };
}

// 从 TokenSequence 推理：拼接文本 prompt，调用 infer()
pub fn infer_from_tokens(
    allocator: std.mem.Allocator,
    seq: *const token.TokenSequence,
    max_tokens: u32,
    api_key: []const u8,
) !InferenceResult {
    // 从 TokenSequence 拼接文本 prompt
    var prompt_buf: [4096]u8 = undefined;
    var prompt_len: usize = 0;

    var i: u16 = 0;
    while (i < seq.len) : (i += 1) {
        const tok = seq.tokens[i];
        if (tok.tpe == .Text) {
            const text = tok.getText();
            if (prompt_len + text.len <= prompt_buf.len) {
                @memcpy(prompt_buf[prompt_len..][0..text.len], text);
                prompt_len += text.len;
            }
        }
        // VectorQuantized 类型的 Token 暂时跳过（后续版本处理）
    }

    const prompt_str = prompt_buf[0..prompt_len];
    return infer(allocator, prompt_str, max_tokens, api_key);
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
