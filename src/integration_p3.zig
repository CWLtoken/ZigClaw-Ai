// src/integration_p3.zig
// ZigClaw V2.4 Phase3 | IoRequest 架构 | 真实物理内存搬运
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");
const router = @import("router.zig");

var test_window = storage.StreamWindow.init();
var test_body_pool = storage.BodyBufferPool.init();

// 辅助：写入 fake CQE，user_data 必须与对应 SQE 相同
fn push_cqe(ring: *io_uring.Ring, user_data: u64, res: i32) void {
    const tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    const idx = tail & ring.cq_ring_mask;
    ring.cqes[idx] = .{ .user_data = user_data, .res = res, .flags = 0 };
    @atomicStore(u32, ring.cq_tail, tail + 1, .release);
}

test "Integration: Protocol State Machine Lifecycle & Defenses" {
    var window = storage.StreamWindow.init();
    var test_header = core.TokenStreamHeader.init();
    mem.writeInt(u64, test_header.data[0..8], 42, .little);
    mem.writeInt(u32, test_header.data[8..12], 100, .little);
    window.push_header(test_header);

    var proto = try protocol.Protocol.init(&window, &test_body_pool, router.default_handler);

    // ── 用例1：user_data 不匹配 → 立即 reset() → .Idle (I-C) ──
    proto.state = .Idle;
    proto.begin_receive(42, -1, router.default_handler);

    var io_req1 = io_uring.IoRequest{ .stream_id = 99, .buf_ptr = null };
    {
        const idx = proto.reactor.ring.sq_tail.* & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.Read),
            .fd = 0, .off = 0,
            .addr = 0, .len = 13,
            .user_data = @intFromPtr(&io_req1),
            .flags = 0, .ioprio = 0, .__pad1 = 0,
            .buf_index = 0, .personality = 0,
            .splice_fd_in = 0, .addr3 = 0, .__pad2 = 0,
        };
        @atomicStore(u32, proto.reactor.ring.sq_tail, proto.reactor.ring.sq_tail.* + 1, .release);
    }
    push_cqe(&proto.reactor.ring, @intFromPtr(&io_req1), -1);

    // I-C: 错误后立即 reset()，返回 .Idle
    const s1 = proto.step();
    try testing.expect(std.meta.activeTag(s1) == .Error); // 先确认进入错误状态
    proto.reset(); // 清理状态
    try testing.expectEqual(protocol.State.Idle, proto.state); // 确认回到 Idle

    // ── 用例2：HeaderRecv 成功 → .BodyRecv ──
    // 重新初始化 proto，避免状态污染
    proto = try protocol.Protocol.init(&window, &test_body_pool, router.default_handler);
    // 重新 push_header，因为用例1的 reset() 释放了槽位
    window.push_header(test_header);
    proto.begin_receive(42, -1, router.default_handler);

    var fake_hdr: [13]u8 align(64) = undefined;
    @memset(&fake_hdr, 0xAA);
    var io_req2 = io_uring.IoRequest{ .stream_id = 42, .buf_ptr = &fake_hdr };

    {
        const idx = proto.reactor.ring.sq_tail.* & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.Read),
            .fd = 0, .off = 0,
            .addr = @intFromPtr(&fake_hdr),
            .len = 13,
            .user_data = @intFromPtr(&io_req2),
            .flags = 0, .ioprio = 0, .__pad1 = 0,
            .buf_index = 0, .personality = 0,
            .splice_fd_in = 0, .addr3 = 0, .__pad2 = 0,
        };
        @atomicStore(u32, proto.reactor.ring.sq_tail, proto.reactor.ring.sq_tail.* + 1, .release);
    }
    push_cqe(&proto.reactor.ring, @intFromPtr(&io_req2), 13);

    try testing.expectEqual(protocol.State.BodyRecv, proto.step());

    // ── 用例3：BodyRecv 部分读取 → 保持 .BodyRecv ──
    var fake_body1: [40]u8 align(64) = undefined;
    @memset(&fake_body1, 0xBB);
    var io_req3 = io_uring.IoRequest{ .stream_id = 42, .buf_ptr = &fake_body1 };

    {
        const idx = proto.reactor.ring.sq_tail.* & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.Read),
            .fd = 0, .off = 0,
            .addr = @intFromPtr(&fake_body1),
            .len = 40,
            .user_data = @intFromPtr(&io_req3),
            .flags = 0, .ioprio = 0, .__pad1 = 0,
            .buf_index = 0, .personality = 0,
            .splice_fd_in = 0, .addr3 = 0, .__pad2 = 0,
        };
        @atomicStore(u32, proto.reactor.ring.sq_tail, proto.reactor.ring.sq_tail.* + 1, .release);
    }
    push_cqe(&proto.reactor.ring, @intFromPtr(&io_req3), 40);

    try testing.expectEqual(protocol.State.BodyRecv, proto.step());

    // ── 用例4：BodyRecv remaining=0 → .BodyDone ──
    var fake_body2: [60]u8 align(64) = undefined;
    @memset(&fake_body2, 0xCC);
    var io_req4 = io_uring.IoRequest{ .stream_id = 42, .buf_ptr = &fake_body2 };

    {
        const idx = proto.reactor.ring.sq_tail.* & io_uring.SQ_MASK;
        proto.reactor.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.Read),
            .fd = 0, .off = 0,
            .addr = @intFromPtr(&fake_body2),
            .len = 60,
            .user_data = @intFromPtr(&io_req4),
            .flags = 0, .ioprio = 0, .__pad1 = 0,
            .buf_index = 0, .personality = 0,
            .splice_fd_in = 0, .addr3 = 0, .__pad2 = 0,
        };
        @atomicStore(u32, proto.reactor.ring.sq_tail, proto.reactor.ring.sq_tail.* + 1, .release);
    }
    push_cqe(&proto.reactor.ring, @intFromPtr(&io_req4), 60);

    try testing.expectEqual(protocol.State.BodyDone, proto.step());

    const final_header = window.access_header(42).?;
    const final_len = mem.readInt(u32, final_header.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_len);

    // 第2步：BodyDone 后自动复位
    proto.reset();
    try testing.expectEqual(protocol.State.Idle, proto.state);
}
