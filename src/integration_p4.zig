// src/integration_p4.zig
// ZigClaw V2.4 Phase4 | IoRequest 架构 | 单线程 Happy Path
const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

var test_body_pool = storage.BodyBufferPool.init();

const TEST_STREAM_ID: u64 = 42;

test "Phase4: IoRequest 架构 - 单线程 Happy Path" {
    var window = storage.StreamWindow.init();
    var test_header = core.TokenStreamHeader.init();
    mem.writeInt(u64, test_header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, test_header.data[8..12], 100, .little);
    window.push_header(test_header);

    // fake 数据缓冲区
    var fake_hdr_buf: [13]u8 align(64) = undefined;
    var fake_body_buf: [100]u8 align(64) = undefined;
    @memset(&fake_hdr_buf, 0xAA);
    @memset(&fake_body_buf, 0xBB);

    var proto = protocol.Protocol.init(&window, &test_body_pool);
    proto.begin_receive(TEST_STREAM_ID);

    // ── Step 1: HeaderRecv ──
    // 提交 SQE：读取 header (13 bytes)
    var io_req_hdr = io_uring.IoRequest{ .stream_id = TEST_STREAM_ID, .buf_ptr = &fake_hdr_buf };
    {
        const idx = proto.reactor.ring.sq_tail.* & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.Read),
            .fd = 0, .off = 0,
            .addr = @intFromPtr(&fake_hdr_buf),
            .len = 13,
            .user_data = @intFromPtr(&io_req_hdr),
            .flags = 0, .ioprio = 0, .__pad1 = 0,
            .buf_index = 0, .personality = 0,
            .splice_fd_in = 0, .addr3 = 0, .__pad2 = 0,
        };
        @atomicStore(u32, proto.reactor.ring.sq_tail, proto.reactor.ring.sq_tail.* + 1, .release);
    }
    // 写入 fake CQE：header 读取完成，res=13
    {
        const tail = @atomicLoad(u32, proto.reactor.ring.cq_tail, .acquire);
        const idx = tail & proto.reactor.ring.cq_ring_mask;
        proto.reactor.ring.cqes[idx] = .{
            .user_data = @intFromPtr(&io_req_hdr),
            .res = 13,
            .flags = 0,
        };
        @atomicStore(u32, proto.reactor.ring.cq_tail, tail + 1, .release);
    }
    try testing.expectEqual(protocol.State.BodyRecv, proto.step());

    // ── Step 2: BodyRecv ──
    // 提交 SQE：读取 body (100 bytes)
    var io_req_body = io_uring.IoRequest{ .stream_id = TEST_STREAM_ID, .buf_ptr = &fake_body_buf };
    {
        const idx = proto.reactor.ring.sq_tail.* & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.Read),
            .fd = 0, .off = 0,
            .addr = @intFromPtr(&fake_body_buf),
            .len = 100,
            .user_data = @intFromPtr(&io_req_body),
            .flags = 0, .ioprio = 0, .__pad1 = 0,
            .buf_index = 0, .personality = 0,
            .splice_fd_in = 0, .addr3 = 0, .__pad2 = 0,
        };
        @atomicStore(u32, proto.reactor.ring.sq_tail, proto.reactor.ring.sq_tail.* + 1, .release);
    }
    // 写入 fake CQE：body 读取完成，res=100 (remaining 变为 0 → BodyDone)
    {
        const tail = @atomicLoad(u32, proto.reactor.ring.cq_tail, .acquire);
        const idx = tail & proto.reactor.ring.cq_ring_mask;
        proto.reactor.ring.cqes[idx] = .{
            .user_data = @intFromPtr(&io_req_body),
            .res = 100,
            .flags = 0,
        };
        @atomicStore(u32, proto.reactor.ring.cq_tail, tail + 1, .release);
    }
    try testing.expectEqual(protocol.State.BodyDone, proto.step());

    // 验证：header 中的 remaining 已更新为 0
    const final_header = window.access_header(TEST_STREAM_ID).?;
    const final_len = mem.readInt(u32, final_header.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_len);
}
