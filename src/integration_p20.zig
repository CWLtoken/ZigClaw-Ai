// src/integration_p20.zig
// ZigClaw V2.4 Phase10 | 异步业务处理器测试 | 回调模式
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const reactor = @import("reactor.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");
const router = @import("router.zig");

test "Phase10: 异步回显处理器 - 回调模式" {
    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();
    
    const stream_id: u64 = 42;
    const body = "hello";
    
    // 构造 header
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], stream_id, .little);
    mem.writeInt(u32, header.data[8..12], @intCast(body.len), .little);
    header.data[12] = 0x02;
    window.push_header(header);
    
    // 写入 body 到 body_pool
    const buf_ptr, const buf_len = body_pool.get_write_slice(stream_id);
    _ = buf_len;
    @memcpy(buf_ptr[0..body.len], body);
    body_pool.advance(stream_id, body.len);
    
    // 创建 Protocol，注入异步处理器
    var proto = try protocol.Protocol.init(&window, &body_pool, router.default_handler);
    proto.async_handler = router.async_echo_handler;
    proto.begin_receive(stream_id, -1, router.default_handler, proto.async_handler.?);
    
    // 模拟 BodyDone 分支：手动设置 ctx（模拟 Protocol 内部行为）
    proto.ctx = router.RequestContext{
        .stream_id = stream_id,
        .op_code = 0x02,
        .body_pool = &body_pool,
        .response_buf = [_]u8{0} ** 4096,
        .response_len = 0,
        .userdata = @ptrCast(&proto),
        .body_len = @intCast(body.len),
    };
    
    // 调用 async_echo_handler（模拟 BodyDone 分支进入 WaitingBusiness）
    const async_h = proto.async_handler.?;
    async_h(&proto.ctx, protocol.Protocol.onResponseReady, &proto.cancel_token);
    
    // 验证：onResponseReady 被调用，proto.response_ready 应该是 true
    try testing.expect(@atomicLoad(bool, &proto.response_ready, .acquire) == true);
    
    // 验证：async_echo_handler 已经填充了 proto.ctx.response_buf
    const expected_response = "hello [ACK]\n";
    try testing.expectEqualStrings(expected_response, proto.ctx.response_buf[0..proto.ctx.response_len]);
    
    std.debug.print("\n✅ Phase10 异步回显测试通过：回调正确触发\n", .{});
}
