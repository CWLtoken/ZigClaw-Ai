// src/inference.zig
// ZigClaw V2.4 Phase13 | 推理引擎抽象层 | 请求→推理→响应闭环
const std = @import("std");
const router = @import("router.zig");

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
};

/// 阻塞式推理接口（阶段 13 用同步版本）
/// 阶段 14 将异步化
pub fn infer(req: InferenceRequest) InferenceResponse {
    // 阶段 13 初次实现：调用本地 echo 模拟推理
    // TODO: 阶段 14 接入真实的推理服务（HTTP/gRPC/本地库）
    
    var resp = InferenceResponse{
        .text = [_]u8{0} ** 4096,
        .len = 0,
        .tokens_used = 0,
    };
    
    // 模拟推理：将 prompt 内容复制为响应（echo 模式）
    const copy_len = @min(req.prompt.len, 4096);
    @memcpy(resp.text[0..copy_len], req.prompt[0..copy_len]);
    resp.len = @intCast(copy_len);
    resp.tokens_used = @intCast(copy_len / 4); // 粗略估算：4 字符 ≈ 1 token
    
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
    
    // 将推理结果写入响应缓冲区
    @memcpy(ctx.response_buf[0..resp.len], resp.text[0..resp.len]);
    ctx.response_len = resp.len;
}
