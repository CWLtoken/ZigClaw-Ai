// src/integration_p17.zig
// ZigClaw V2.4 | 简化测试 | 单流状态机测试

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

const TEST_STREAM_ID: u64 = 1001;
const TEST_BODY_LEN: u32 = 100;

test "Phase17: Single stream state machine test" {
    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();
    var proto = try protocol.Protocol.init(&window, &body_pool);
    
    try testing.expectEqual(protocol.State.Idle, proto.state);
    
    proto.begin_receive(TEST_STREAM_ID);
    try testing.expectEqual(protocol.State.HeaderRecv, proto.state);
    
    // 构造报头（remaining = TEST_BODY_LEN）
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, header.data[8..12], TEST_BODY_LEN, .little);
    window.push_header(header);
    
    // 注入 HeaderRecv CQE
    var recv_buf: [13]u8 = undefined;
    @memcpy(recv_buf[0..13], &header.data);
    
    var io_req = io_uring.IoRequest{
        .stream_id = TEST_STREAM_ID,
        .buf_ptr = @as(?*anyopaque, @ptrCast(&recv_buf)),
    };
    
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
    var body_buf: [TEST_BODY_LEN]u8 = undefined;
    @memset(&body_buf, 0xCC);
    
    const dest_ptr, const offset = body_pool.get_write_slice(TEST_STREAM_ID);
    _ = offset;
    @memcpy(dest_ptr[0..TEST_BODY_LEN], &body_buf);
    body_pool.advance(TEST_STREAM_ID, TEST_BODY_LEN);
    
    // 注意：不要设置 remaining = 0，让 protocol.zig 自动计算
    
    // 注入 BodyRecv CQE（res = TEST_BODY_LEN）
    io_req.buf_ptr = @as(?*anyopaque, @ptrCast(&body_buf));
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
            std.debug.print("Error reason: {s}\n", .{err.reason});
        },
        else => {
            std.debug.print("Unexpected state: {s}\n", .{@tagName(state2)});
        },
    }
    
    try testing.expectEqual(protocol.State.BodyDone, state2);
    
    // 验证：remaining 应该为 0
    const h = window.access_header(TEST_STREAM_ID).?;
    const final_len = mem.readInt(u32, h.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_len);
    
    // 重置状态
    proto.state = .Idle;
    proto.active_stream_id = 0;
}
