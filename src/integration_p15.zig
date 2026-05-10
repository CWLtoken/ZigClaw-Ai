// src/integration_p15.zig
// ZigClaw V2.4 阶段 5 | Protocol 报头接收测试（简化版）
// 目标：验证 Protocol 通过模拟 io_uring RECV 接收 13 字节报头，状态机 HeaderRecv → BodyRecv

const std = @import("std");
const router = @import("router.zig");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");
const protocol = @import("protocol.zig");

const TEST_STREAM_ID: u64 = 42;

test "Phase15: Protocol receives 13-byte header via io_uring RECV" {
    // ===========================================================
    // 阶段 1：创建 Protocol（内部创建 Ring）
    // ===========================================================
    var window = storage.StreamWindow.init();
    var test_body_pool = storage.BodyBufferPool.init();
    var proto = try protocol.Protocol.init(&window, &test_body_pool);
    
    // 初始状态：Idle
    try testing.expectEqual(protocol.State.Idle, proto.state);
    
    // 开始接收
    proto.begin_receive(TEST_STREAM_ID);
    try testing.expectEqual(protocol.State.HeaderRecv, proto.state);

    // ===========================================================
    // 阶段 2：构造 13 字节报头（TokenStreamHeader 格式）
    // ===========================================================
    var recv_buf: [4096]u8 = undefined;
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, header.data[8..12], 4096, .little);
    header.data[12] = 0;
    @memcpy(recv_buf[0..13], &header.data);

    // 将接收到的报头写入 StreamWindow
    window.push_header(header);

    // ===========================================================
    // 阶段 3：验证接收到的报头内容
    // ===========================================================
    const received_stream_id = mem.readInt(u64, recv_buf[0..8], .little);
    const received_total_len = mem.readInt(u32, recv_buf[8..12], .little);
    try testing.expectEqual(@as(u64, TEST_STREAM_ID), received_stream_id);
    try testing.expectEqual(@as(u32, 4096), received_total_len);
    try testing.expectEqual(@as(u8, 0), recv_buf[12]);

    // ===========================================================
    // 阶段 4：手动推入 CQE（模拟 io_uring RECV 完成）
    // ===========================================================
    var io_req = io_uring.IoRequest{
        .stream_id = TEST_STREAM_ID,
        .buf_ptr = @as(?*anyopaque, @ptrCast(&recv_buf)),
    };

    const ring = &proto.reactor.ring;
    const cq_tail_loc = @atomicLoad(u32, ring.cq_tail, .acquire);
    const cqe_idx = cq_tail_loc & ring.cq_ring_mask;
    const fake_cqe = &ring.cqes[cqe_idx];
    fake_cqe.* = .{
        .user_data = @intFromPtr(&io_req),
        .res = 13,
        .flags = 0,
    };
    
    io_req.buf_ptr = @as(?*anyopaque, @ptrCast(&recv_buf));
    @atomicStore(u32, ring.cq_tail, cq_tail_loc + 1, .release);

    // ===========================================================
    // 阶段 5：调用 Protocol.step() 进行状态转移
    // ===========================================================
    const state = proto.step();
    try testing.expectEqual(protocol.State.BodyRecv, state);
}
