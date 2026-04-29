// src/integration_p21.zig
// 阶段 11 测试：线程安全回调 — 异步 handler 在独立线程中运行
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const reactor = @import("reactor.zig");
const protocol = @import("protocol.zig");
const router = @import("router.zig");
const io_uring = @import("io_uring.zig");

// 线程函数：直接接收三个参数（ctx, on_done, cancel_token）
fn threadHandler(ctx: *router.RequestContext, on_done: *const fn (*router.RequestContext) void, cancel_token: *u32) void {
    _ = cancel_token; // 测试中不检查取消标志
    
    // 模拟业务处理：回显 body + ACK
    const body_data = ctx.body_pool.get_read_slice(ctx.stream_id, ctx.body_len);
    var offset: usize = 0;
    @memcpy(ctx.response_buf[0..ctx.body_len], body_data);
    offset += ctx.body_len;
    const ack = " [ACK]\n";
    @memcpy(ctx.response_buf[offset..offset + ack.len], ack);
    offset += ack.len;
    ctx.response_len = @intCast(offset);
    
    // 通知 Protocol 完成（使用原子操作）
    on_done(ctx);
}

// 真正的多线程异步 handler：在独立线程中运行
fn threadedEchoHandler(ctx: *router.RequestContext, on_done: *const fn (*router.RequestContext) void, cancel_token: *u32) void {
    // 启动线程执行异步处理
    // std.Thread.spawn 的第三个参数是一个 tuple，会被展开为函数的参数
    const thread = std.Thread.spawn(.{}, threadHandler, .{ctx, on_done, cancel_token}) catch unreachable;
    
    _ = thread; // 线程在后台运行
}

test "P21: 线程安全回调 — 异步 handler 在独立线程中运行" {
    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();

    // 创建 Protocol，使用多线程异步 handler
    var proto = try protocol.Protocol.init(&window, &body_pool, router.default_handler);
    proto.async_handler = threadedEchoHandler;
    
    // 注册连接
    const stream_id: u64 = 0x1234567890ABCDEF;
    const fd: i32 = 10;
    proto.begin_receive(stream_id, fd, router.default_handler, proto.async_handler.?);

    // 推送报头
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], stream_id, .little);
    mem.writeInt(u32, header.data[8..12], 13, .little);
    header.data[12] = 0x01;
    window.push_header(header);

    // 设置 body 数据
    const body_data = "Hello, World!";
    const buf_ptr, const buf_len = body_pool.get_write_slice(stream_id);
    _ = buf_len;
    @memcpy(buf_ptr[0..body_data.len], body_data);
    body_pool.advance(stream_id, body_data.len);

    // 模拟 HeaderRecv → BodyRecv → BodyDone
    _ = proto.step(); // HeaderRecv: 提交 RECV
    
    // 模拟 RECV 完成（HeaderRecv → BodyRecv）
    // 这里需要模拟 io_uring CQE，但是为了简化，我们直接设置状态
    proto.state = .BodyRecv;
    
    // 模拟 BodyRecv 完成（BodyRecv → BodyDone）
    // 直接设置状态为 BodyDone，并手动设置 ctx
    proto.state = .BodyDone;
    
    // 手动执行 BodyDone 分支（进入 WaitingBusiness）
    const op_code = proto.header_recv_buf[12];
    proto.ctx = router.RequestContext{
        .stream_id = stream_id,
        .op_code = op_code,
        .body_pool = &body_pool,
        .response_buf = [_]u8{0} ** 4096,
        .response_len = 0,
        .userdata = @ptrCast(&proto),
        .body_len = @intCast(body_data.len),
    };
    
    // 调用异步 handler
    const async_h = proto.async_handler.?;
    proto.ctx.userdata = @ptrCast(&proto);
    async_h(&proto.ctx, protocol.Protocol.onResponseReady, &proto.cancel_token);
    proto.state = .WaitingBusiness;
    
    // 等待异步处理完成（轮询）
    var retries: u32 = 0;
    while (retries < 100000) {
        const state = proto.step();
        if (state == .SendDone) {
            break;
        }
        if (state == .Error) {
            std.debug.print("Error: {s}\n", .{state.Error.reason});
            try testing.expect(false);
            break;
        }
        retries += 1;
    }
    
    try testing.expect(proto.state == .SendDone);
    
    // 验证响应数据
    const expected = "Hello, World! [ACK]\n";
    try testing.expectEqualStrings(expected, proto.send_buf[0..proto.ctx.response_len]);
    
    // 清理
    proto.reset();
    
    std.debug.print("\n✅ P21 测试通过：线程安全回调正常工作\n", .{});
}
