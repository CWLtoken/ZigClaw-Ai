// src/integration_p18.zig
// ZigClaw V2.4 Phase8 | 双向引擎 | 完整 RESPONSE 闭环测试
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

// 辅助：写入 fake CQE
fn push_cqe(ring: *io_uring.Ring, user_data: u64, res: i32) void {
    const tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    const idx = tail & ring.cq_ring_mask;
    ring.cqes[idx] = .{ .user_data = user_data, .res = res, .flags = 0 };
    @atomicStore(u32, ring.cq_tail, tail + 1, .release);
}

test "Phase8: 双向引擎 - 完整 RESPONSE 闭环" {
    // 创建 Ring
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    // 创建 Protocol + window + body_pool
    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();

    // 准备 stream header（50 字节 body）
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], 42, .little);
    mem.writeInt(u32, header.data[8..12], 50, .little);
    window.push_header(header);

    // 使用 init_with_ring
    var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring);
    proto.begin_receive(42, -1);

    // 准备数据缓冲区
    var fake_hdr: [13]u8 align(64) = undefined;
    var fake_body: [50]u8 align(64) = undefined;
    @memset(&fake_hdr, 0xAA);
    @memset(&fake_body, 0xBB);

    var io_req = io_uring.IoRequest{ .stream_id = 42, .buf_ptr = undefined };

    // 步骤 1: HeaderRecv
    io_req.buf_ptr = &fake_hdr;
    push_cqe(&ring, @intFromPtr(&io_req), 13);
    const s1 = proto.step();
    try testing.expectEqual(protocol.State.BodyRecv, s1);

    // 步骤 2: BodyRecv（提交 RECV）
    _ = proto.reactor.submit(0, 0) catch 0;

    // 注入 BodyRecv 的 CQE
    io_req.buf_ptr = &fake_body;
    push_cqe(&ring, @intFromPtr(&io_req), 50);
    const s2 = proto.step();
    try testing.expectEqual(protocol.State.BodyDone, s2);

    // 步骤 3: BodyDone → 自动准备 SEND（step() 内部处理）
    // 需要提交 SEND SQE
    _ = proto.reactor.submit(0, 0) catch 0;

    // 步骤 4: 模拟 SEND 完成，触发进入 SendDone
    // 注入 SEND 的 CQE
    push_cqe(&ring, @intFromPtr(&io_req), @intCast(proto.send_buf.len));
    const s3 = proto.step();
    try testing.expectEqual(protocol.State.SendDone, s3);

    // 验证：SendDone 是终态
    const s4 = proto.step();
    try testing.expectEqual(protocol.State.SendDone, s4);

    // 清理
    proto.reset();
    try testing.expectEqual(protocol.State.Idle, proto.state);
}
