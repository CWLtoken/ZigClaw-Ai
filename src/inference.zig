// src/inference.zig
// ZigClaw V2.4 Phase14 | 推理引擎抽象层 | 真实 HTTP 推理接入
const std = @import("std");
const router = @import("router.zig");
const http_client = @import("http_client.zig");

/// 推理请求
pub const InferenceRequest = struct {
    prompt: []const u8,         // 用户输入（从 body_pool 提取）
    max_tokens: u32,
    temperature: f32,
};

/// 推理响应
pub const InferenceResponse = struct {
    text: [4096]u8,             // 推理结果
    len: u32,
    tokens_used: u32,
    error_occurred: bool = false,
};

/// 阻塞式推理接口（阶段 14 接入真实 HTTP 推理服务）
pub fn infer(req: InferenceRequest) InferenceResponse {
    // 构造 Ollama API 请求
    const http_req = http_client.HttpRequest{
        .host = "127.0.0.1",
        .port = 11434,
        .path = "/api/generate",
        .body = std.fmt.allocPrint(std.heap.page_allocator, 
            "{{\"model\":\"llama3\",\"prompt\":\"{s}\",\"stream\":false}}", 
            .{req.prompt}) catch {
                // 内存分配失败，返回错误响应
                return InferenceResponse{
                    .text = [_]u8{0} ** 4096,
                    .len = 0,
                    .tokens_used = 0,
                    .error_occurred = true,
                };
            },
    };
    defer std.heap.page_allocator.free(http_req.body);

    // 发送 HTTP POST 请求
    const http_resp = http_client.post(http_req) catch {
        return InferenceResponse{
            .text = [_]u8{0} ** 4096,
            .len = 0,
            .tokens_used = 0,
            .error_occurred = true,
        };
    };

    if (http_resp.error_occurred or http_resp.status_code != 200) {
        return InferenceResponse{
            .text = [_]u8{0} ** 4096,
            .len = 0,
            .tokens_used = 0,
            .error_occurred = true,
        };
    }

    // 解析响应 JSON，提取 "response" 字段
    var resp = InferenceResponse{
        .text = [_]u8{0} ** 4096,
        .len = 0,
        .tokens_used = 0,
    };

    // 简单 JSON 解析：查找 "response":" 之后的内容
    const body = http_resp.body_buf[0..http_resp.body_len];
    if (parse_response_field(body)) |response_text| {
        const copy_len = @min(response_text.len, 4096);
        @memcpy(resp.text[0..copy_len], response_text[0..copy_len]);
        resp.len = @intCast(copy_len);
        resp.tokens_used = @intCast(copy_len / 4); // 粗略估算
    }

    return resp;
}

/// 推理业务处理器（同步版本）
/// 符合 router.HandlerFn 签名
pub fn inference_handler(ctx: *router.RequestContext) void {
    // 从 body_pool 提取用户输入
    const body_len = ctx.body_len;
    const body_slice = ctx.body_pool.get_read_slice(ctx.stream_id, body_len);
    
    // 构造推理请求
    const req = InferenceRequest{
        .prompt = body_slice,
        .max_tokens = 1000,
        .temperature = 0.7,
    };
    
    // 调用推理引擎
    const resp = infer(req);
    
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

/// 从 JSON 中解析 "response" 字段的值
fn parse_response_field(json: []const u8) ?[]const u8 {
    // 查找 "response":"
    const field_start = std.mem.indexOf(u8, json, "\"response\":\"") orelse return null;
    const value_start = field_start + 12; // 跳过 "\"response\":\""
    
    // 查找结束的引号
    const value_end = std.mem.indexOfPos(u8, json, value_start, "\"") orelse return null;
    
    return json[value_start..value_end];
}
