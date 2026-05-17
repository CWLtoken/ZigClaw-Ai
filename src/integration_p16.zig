// src/integration_p16.zig
// ZigClaw V2.4 阶段 5 | P16: Protocol 基础状态机测试

const testing = @import("std").testing;
const mem = @import("std").mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

const TEST_STREAM_ID: u64 = 42;
const TEST_BODY_LEN: u32 = 32;

test "Phase16: Protocol basic state machine test" {
    var window = storage.StreamWindow.init();
    var test_body_pool = storage.BodyBufferPool.init();
    var proto = try protocol.Protocol.init(&window, &test_body_pool);
    
    try testing.expectEqual(protocol.State.Idle, proto.state);
    
    // 开始接收
    proto.begin_receive(TEST_STREAM_ID);
    try testing.expectEqual(protocol.State.HeaderRecv, proto.state);
    
    // 构造报头（remaining = TEST_BODY_LEN）
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, header.data[8..12], TEST_BODY_LEN, .little);
    window.push_header(header);
    
    // 准备 IoRequest 和 CQE（HeaderRecv）
    var recv_buf: [4096]u8 = undefined;
    @memcpy(recv_buf[0..13], &header.data);
    
    var io_req = io_uring.IoRequest{
        .stream_id = TEST_STREAM_ID,
        .buf_ptr = @as(?*anyopaque, @ptrCast(&recv_buf)),
    };
    
    // 注入 HeaderRecv CQE
    const ring = &proto.reactor.ring;
    const cq_tail_loc = @atomicLoad(u32, ring.cq_tail, .acquire);
    const cqe_idx = cq_tail_loc & ring.cq_ring_mask;
    ring.cqes[cqe_idx] = .{
        .user_data = @intFromPtr(&io_req),
        .res = 13,
        .flags = 0,
    };
    @atomicStore(u32, ring.cq_tail, cq_tail_loc + 1, .release);
    
    // step() 应该转到 BodyRecv
    const state1 = proto.step();
    try testing.expectEqual(protocol.State.BodyRecv, state1);
    
    // 模拟 BodyRecv 完成：写入 body 到 body_pool
    var body: [TEST_BODY_LEN]u8 = undefined;
    @memset(&body, 0xAB);
    
    const slice = test_body_pool.get_write_slice(TEST_STREAM_ID) orelse return error.BodyPoolFull;
    const dest_ptr = slice[0];
    const offset = slice[1];
    _ = offset;
    @memcpy(dest_ptr[0..TEST_BODY_LEN], &body);
    test_body_pool.advance(TEST_STREAM_ID, TEST_BODY_LEN);
    
    // 注意：不要在这里设置 remaining = 0
    // protocol.zig 会自动计算 remaining - consumed
    // 我们需要设置 remaining = TEST_BODY_LEN，让 protocol.zig 处理后变为 0
    
    // 注入 BodyRecv CQE（res = TEST_BODY_LEN）
    io_req.buf_ptr = @as(?*anyopaque, @ptrCast(&body));
    const cq_tail_loc2 = @atomicLoad(u32, ring.cq_tail, .acquire);
    const cqe_idx2 = cq_tail_loc2 & ring.cq_ring_mask;
    ring.cqes[cqe_idx2] = .{
        .user_data = @intFromPtr(&io_req),
        .res = TEST_BODY_LEN,
        .flags = 0,
    };
    @atomicStore(u32, ring.cq_tail, cq_tail_loc2 + 1, .release);
    
    // step() 应该转到 BodyDone
    const state2 = proto.step();
    
    // 调试：打印状态
    switch (state2) {
        .BodyDone => {},
        .Error => |err| {
            @import("std").debug.print("Error code: {d}\n", .{err.code});
        },
        else => {
            @import("std").debug.print("Unexpected state: {s}\n", .{@tagName(state2)});
        },
    }
    
    try testing.expectEqual(protocol.State.BodyDone, state2);
    
    // 验证：remaining 应该为 0
    const final_header = window.access_header(TEST_STREAM_ID).?;
    const final_len = mem.readInt(u32, final_header.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_len);
    
    // 验证 body 内容
    const body_slice = test_body_pool.get_read_slice(TEST_STREAM_ID, TEST_BODY_LEN);
    try testing.expectEqual(@as(u8, 0xAB), body_slice[0]);
    
    // 重置
    proto.state = .Idle;
    proto.active_stream_id = 0;
}
