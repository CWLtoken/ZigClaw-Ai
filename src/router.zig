// src/router.zig — 请求路由层
// 职责：根据报头的 op_code 将请求分发给对应的处理器
// 军规：仅依赖 core 和 storage，禁止导入 reactor 或 protocol

const core = @import("core.zig");
const storage = @import("storage.zig");

/// 请求上下文：包含 Protocol 在处理请求时需要的所有信息
pub const RequestContext = struct {
    stream_id: u64,
    op_code: u8,
    body_pool: *storage.BodyBufferPool,   // 只读：已接收的数据
    response_buf: [4096]u8,                // 响应缓冲区
    response_len: u32,                     // 响应实际长度
    userdata: ?*anyopaque = null,          // 用于回调：存储 Protocol 指针（类型擦除）
    body_len: u32 = 0,                     // body 实际长度（由 Protocol 在 BodyDone 时设置）
};

/// 业务处理器签名：接收 RequestContext 并填充 response
pub const HandlerFn = *const fn (*RequestContext) void;

/// 异步业务处理器签名：接收 RequestContext 和回调，立即返回
/// 业务完成后调用 on_done(&ctx) 通知 Protocol
pub const AsyncHandlerFn = *const fn (*RequestContext, *const fn (*RequestContext) void) void;

/// 默认处理器：不进行任何业务处理，发送空响应
pub fn default_handler(ctx: *RequestContext) void {
    ctx.response_len = 0;
}

/// echo_handler：回显接收到的数据 + " [ACK]"
pub fn echo_handler(ctx: *RequestContext) void {
    const body_data = ctx.body_pool.get_read_slice(ctx.stream_id, 0);
    var offset: usize = 0;
    @memcpy(ctx.response_buf[0..body_data.len], body_data);
    offset += body_data.len;
    const ack = " [ACK]\n";
    @memcpy(ctx.response_buf[offset..offset + ack.len], ack);
    offset += ack.len;
    ctx.response_len = @intCast(offset);
}

/// 异步回显处理器：模拟异步处理，注册回调后延迟触发
pub fn async_echo_handler(ctx: *RequestContext, on_done: *const fn (*RequestContext) void) void {
    // 使用 ctx.body_len 获取 body 数据
    const body_data = ctx.body_pool.get_read_slice(ctx.stream_id, ctx.body_len);
    var offset: usize = 0;
    @memcpy(ctx.response_buf[0..ctx.body_len], body_data);
    offset += ctx.body_len;
    const ack = " [ACK]\n";
    @memcpy(ctx.response_buf[offset..offset + ack.len], ack);
    offset += ack.len;
    ctx.response_len = @intCast(offset);
    
    // 调用回调通知 Protocol 业务已完成
    on_done(ctx);
}
