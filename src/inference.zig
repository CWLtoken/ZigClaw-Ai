// src/inference.zig
// ZigClaw V2.4 Phase14 | OpenRouter 推理引擎接入
const std = @import("std");
const router = @import("router.zig");
const http_client = @import("http_client.zig");

/// OpenRouter API Key — 从 https://openrouter.ai/settings/api-keys 获取
/// 替换下面的空字符串为实际 Key（由用户自行填入）
pub const OPENROUTER_API_KEY: []const u8 = ""; // ← 在此处填入你的 API Key

/// 推理请求
pub const InferenceRequest = struct {
    prompt: []const u8,
    max_tokens: u32,
    temperature: f32,
};

/// 推理响应
pub const InferenceResponse = struct {
    text: [4096]u8,
    len: u32,
    tokens_used: u32,
    error_occurred: bool = false,
};

/// 阻塞式推理接口（OpenRouter API）
/// 签名：infer(prompt, max_tokens) — 按架构师要求保持不变
pub fn infer(prompt: []const u8, max_tokens: u32) InferenceResponse {
    // 1. 构造 JSON body（OpenRouter Chat Completions API 格式）
    var body_buf: [4096]u8 = undefined;
    const body = std.fmt.bufPrint(&body_buf,
        "{{\"model\":\"openai/gpt-4.1-nano\",\"messages\":[{{\"role\":\"user\",\"content\":\"{s}\"}}],\"max_tokens\":{d}}}",
        .{ prompt, max_tokens }) catch {
        return InferenceResponse{ .text = undefined, .len = 0, .tokens_used = 0, .error_occurred = true };
    };

    // 2. 调用 HTTP 客户端
    const resp = http_client.post(
        "openrouter.ai",
        443,
        "/api/v1/chat/completions",
        body,
        if (OPENROUTER_API_KEY.len > 0) OPENROUTER_API_KEY else "",
    ) catch {
        return InferenceResponse{ .text = undefined, .len = 0, .tokens_used = 0, .error_occurred = true };
    };

    // 3. 解析 JSON 响应，提取 choices[0].message.content
    return parse_openrouter_response(&resp);
}

/// 推理业务处理器（同步版本）
/// 符合 router.HandlerFn 签名
pub fn inference_handler(ctx: *router.RequestContext) void {
    // 从 body_pool 提取用户输入
    const body_len = ctx.body_len;
    const body_slice = ctx.body_pool.get_read_slice(ctx.stream_id, body_len);
    
    // 调用推理引擎
    const resp = infer(body_slice, 1000);
    
    if (resp.error_occurred) {
        // 推理失败，返回错误响应
        const err_msg = "Inference failed";
        @memcpy(ctx.response_buf[0..err_msg.len], err_msg);
        ctx.response_len = @intCast(err_msg.len);
    } else {
        // 将推理结果写入响应缓冲区
        @memcpy(ctx.response_buf[0..resp.len], resp.text[0..resp.len]);
        ctx.response_len = resp.len;
    }
}

/// 解析 OpenRouter JSON 响应，提取 choices[0].message.content
fn parse_openrouter_response(resp: *const http_client.HttpResponse) InferenceResponse {
    const body = resp.body_buf[0..resp.body_len];
    
    // 查找 "content":" 之后的内容
    const content_key = "\"content\":\"";
    const start_idx = std.mem.indexOf(u8, body, content_key) orelse {
        return InferenceResponse{ .text = undefined, .len = 0, .tokens_used = 0, .error_occurred = true };
    };
    
    const content_start = start_idx + content_key.len;
    const remaining = body[content_start..];
    
    // 查找结束的引号
    const end_idx = std.mem.indexOfScalar(u8, remaining, '"') orelse {
        return InferenceResponse{ .text = undefined, .len = 0, .tokens_used = 0, .error_occurred = true };
    };
    
    const content = remaining[0..end_idx];
    
    var result = InferenceResponse{ .text = undefined, .len = 0, .tokens_used = 0, .error_occurred = false };
    const copy_len = @min(content.len, 4096);
    @memcpy(result.text[0..copy_len], content);
    result.len = @intCast(copy_len);
    return result;
}
