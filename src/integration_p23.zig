// src/integration_p23.zig
// ZigClaw V2.4 Phase12 | 压力测试 | 调试 CQ 状态
const std = @import("std");
const router = @import("router.zig");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

test "P23: 调试 CQ 状态" {
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();

    const stream_id: u64 = 9999;

    var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring, router.default_handler);

    var fake_hdr: [13]u8 align(64) = undefined;
    @memset(&fake_hdr, 0xAA);
    var io_req = io_uring.IoRequest{ .stream_id = stream_id, .buf_ptr = &fake_hdr };

    // 开始接收
    proto.begin_receive(stream_id, -1, router.default_handler, null);
    try testing.expectEqual(protocol.State.HeaderRecv, proto.state);

    // 检查 CQ 初始状态
    const cq_head_before = @atomicLoad(u32, proto.reactor.ring.cq_head, .acquire);
    const cq_tail_before = @atomicLoad(u32, proto.reactor.ring.cq_tail, .acquire);
    try testing.expectEqual(cq_head_before, cq_tail_before); // 初始应该相等

    // 注入 HeaderRecv CQE
    const tail = @atomicLoad(u32, proto.reactor.ring.cq_tail, .acquire);
    const idx = tail & proto.reactor.ring.cq_ring_mask;
    proto.reactor.ring.cqes[idx] = .{ .user_data = @intFromPtr(&io_req), .res = 13, .flags = 0 };
    @atomicStore(u32, proto.reactor.ring.cq_tail, tail + 1, .release);

    // 检查 CQ 状态
    const cq_head_after = @atomicLoad(u32, proto.reactor.ring.cq_head, .acquire);
    const cq_tail_after = @atomicLoad(u32, proto.reactor.ring.cq_tail, .acquire);
    try testing.expect(cq_head_after != cq_tail_after); // 应该有 CQE 待处理

    // 调用 step()
    const state1 = proto.step();

    // 检查 step() 后的状态
    // 如果失败，尝试检查 proto.state
    if (state1 == .HeaderRecv) {
        // 可能还在 HeaderRecv，因为 poll() 返回了 Idle
        // 再调用一次 step()
        const state1b = proto.step();
        if (state1b == .BodyRecv) {
            // 成功
        } else {
            // 失败，检查 proto.state
            try testing.expect(false); // 强制失败，看看是什么状态
        }
    } else if (state1 == .BodyRecv) {
        // 成功
    } else {
        // 其他状态，强制失败
        try testing.expect(false);
    }
}
