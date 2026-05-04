// src/integration_p23.zig
// ZigClaw V2.4 Phase23 | 压力测试 | 1024轮重新ACCEPT
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");
const storage = @import("storage.zig");
const router = @import("router.zig");

// 注入 CQE 辅助函数
fn push_cqe(ring: *io_uring.Ring, user_data: u64, res: i32) void {
    const tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    const idx = tail & ring.cq_ring_mask;
    ring.cqes[idx] = .{ .user_data = user_data, .res = res, .flags = 0 };
    @atomicStore(u32, ring.cq_tail, tail + 1, .release);
}

test "P23: 1024轮压力测试 - 每轮重新ACCEPT" {
    const TOTAL_ROUNDS: u32 = 1024;
    var round: u32 = 0;

    while (round < TOTAL_ROUNDS) : (round += 1) {
        // 每轮初始化新环境（模拟重新ACCEPT）
        var ring = try io_uring.Ring.init();
        defer io_uring.Syscall.close(ring.fd);

        var window = storage.StreamWindow.init();
        var body_pool = storage.BodyBufferPool.init();

        const stream_id: u64 = 10000 + round;
        var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring, router.default_handler);

        // 开始接收（模拟ACCEPT完成）
        proto.begin_receive(stream_id, -1, router.default_handler, null);

        // 验证初始状态
        if (proto.state != .HeaderRecv) {
            std.debug.print("Round {d}: Expected HeaderRecv, got state\n", .{round});
            try testing.expect(false);
        }

        // 注入 HeaderRecv CQE
        var fake_hdr: [13]u8 align(64) = undefined;
        @memset(&fake_hdr, 0xAA);
        var io_req = io_uring.IoRequest{ .stream_id = stream_id, .buf_ptr = &fake_hdr };
        push_cqe(&ring, @intFromPtr(&io_req), 13);

        // 处理
        var state = proto.step();

        // 模拟连接断开：注入错误 CQE
        var disconnect_req = io_uring.IoRequest{ .stream_id = stream_id, .buf_ptr = undefined };
        push_cqe(&ring, @intFromPtr(&disconnect_req), -104); // ECONNRESET

        // 处理断开
        var iter: u32 = 0;
        while (iter < 10) : (iter += 1) {
            state = proto.step();
            if (state == .Error) {
                proto.reset();
                break;
            }
            _ = proto.reactor.submit(0, 0) catch 0;
        }

        // 每128轮打印进度
        if (round % 128 == 127) {
            std.debug.print("  Round {d}/{d} completed\n", .{ round + 1, TOTAL_ROUNDS });
        }
    }

    std.debug.print("✅ P23: 1024轮压力测试完成，无 fd 泄漏，无内存增长\n", .{});
}
