// src/integration_p19.zig
// ZigClaw V2.4 Phase9 | 业务处理器回显测试 | 同步版本
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");
const router = @import("router.zig");

// echo_handler：回显接收到的数据 + "ACK"
fn echo_handler(ctx: *router.RequestContext) void {
    // 从 body_pool 读取已接收的数据
    const body_data = ctx.body_pool.get_read_slice(ctx.stream_id, 0);
    
    // 构造响应：回显数据 + " [ACK]"
    const ack = " [ACK]\n";
    var offset: usize = 0;
    
    // 复制 body 数据
    @memcpy(ctx.response_buf[0..body_data.len], body_data);
    offset += body_data.len;
    
    // 添加 ACK
    @memcpy(ctx.response_buf[offset..offset + ack.len], ack);
    offset += ack.len;
    
    ctx.response_len = @intCast(offset);
}

test "Phase9: 业务处理器回显测试 - 同步版本" {
    // 创建 Ring
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    // 创建 Protocol + window + body_pool
    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();

    // 准备 stream header（32 字节 body）
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], 42, .little);
    mem.writeInt(u32, header.data[8..12], 32, .little);
    header.data[12] = 1; // op_code = 1（业务请求）
    window.push_header(header);

    // 使用 init_with_ring，注入 echo_handler
    var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring, echo_handler);
    proto.begin_receive(42, -1, echo_handler);

    // 准备数据缓冲区
    var fake_hdr: [13]u8 align(64) = undefined;
    var fake_body: [32]u8 align(64) = undefined;
    @memset(&fake_hdr, 0xAA);
    @memset(&fake_body, 0xBB);

    var io_req = io_uring.IoRequest{ .stream_id = 42, .buf_ptr = undefined };

    // 步骤 1: HeaderRecv
    io_req.buf_ptr = &fake_hdr;
    // 注入 HeaderRecv 的 CQE
    const tail1 = @atomicLoad(u32, ring.cq_tail, .acquire);
    ring.cqes[tail1 & ring.cq_ring_mask] = .{ .user_data = @intFromPtr(&io_req), .res = 13, .flags = 0 };
    @atomicStore(u32, ring.cq_tail, tail1 + 1, .release);
    
    const s1 = proto.step();
    try testing.expectEqual(protocol.State.BodyRecv, s1);

    // 步骤 2: BodyRecv
    _ = proto.reactor.submit(0, 0) catch 0;
    
    // 注入 BodyRecv 的 CQE
    io_req.buf_ptr = &fake_body;
    const tail2 = @atomicLoad(u32, ring.cq_tail, .acquire);
    ring.cqes[tail2 & ring.cq_ring_mask] = .{ .user_data = @intFromPtr(&io_req), .res = 32, .flags = 0 };
    @atomicStore(u32, ring.cq_tail, tail2 + 1, .release);
    
    const s2 = proto.step();
    try testing.expectEqual(protocol.State.BodyDone, s2);

    // 步骤 3: BodyDone → 调用 echo_handler → 自动 SEND
    _ = proto.reactor.submit(0, 0) catch 0;
    
    // 步骤 4: 等待 SEND 完成，进入 SendDone
    // 注入 SEND 的 CQE
    const tail3 = @atomicLoad(u32, ring.cq_tail, .acquire);
    ring.cqes[tail3 & ring.cq_ring_mask] = .{ .user_data = @intFromPtr(&io_req), .res = 37, .flags = 0 }; // 32 + 5 ("ACK\n")
    @atomicStore(u32, ring.cq_tail, tail3 + 1, .release);
    
    const s3 = proto.step();
    try testing.expectEqual(protocol.State.SendDone, s3);

    // 验证：SendDone 是终态
    const s4 = proto.step();
    try testing.expectEqual(protocol.State.SendDone, s4);

    // 清理
    proto.reset();
    try testing.expectEqual(protocol.State.Idle, proto.state);
}
