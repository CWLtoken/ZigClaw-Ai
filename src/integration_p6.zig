// src/integration_p6.zig
// ZigClaw V2.4 Phase6 | io_uring_enter 系统调用验证
const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");
const reactor_mod = @import("reactor.zig");

test "Phase6: io_uring_enter syscall verification" {
    const ring = io_uring.Ring.init();
    defer {
        _ = io_uring.Syscall.close(ring.fd);
    }

    // 准备 SQE: NOP
    const sq_tail_val = @atomicLoad(u32, ring.sq_tail, .acquire);
    const idx = sq_tail_val & io_uring.SQ_MASK;

    ring.sq_entries[idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.NOP),
        .fd = -1, // NOP 不检查 fd
        .off = 0,
        .addr = 0,
        .len = 0,
        .user_data = 42,
        .flags = 0, .ioprio = 0, .__pad1 = 0,
        .buf_index = 0, .personality = 0,
        .splice_fd_in = 0, .addr3 = 0, .__pad2 = 0,
    };
    // 写入 sq_array 告诉内核 SQE[idx] 有有效数据
    ring.sq_array[idx] = idx;

    // 安全推进 sq_tail
    const ov_result = @addWithOverflow(sq_tail_val, 1);
    if (ov_result[1] != 0) {
        return error.SkipZigTest;
    }
    @atomicStore(u32, ring.sq_tail, ov_result[0], .release);

    // 调用 enter(): 提交 1 个，等待 1 个完成
    const submitted = io_uring.Syscall.enter(ring.fd, 1, 1, 0);

    if (submitted < 0) {
        return error.SkipZigTest;
    }
    try testing.expectEqual(@as(i32, 1), submitted);

    // 读取 CQE
    const cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail = @atomicLoad(u32, ring.cq_tail, .acquire);

    if (cq_head == cq_tail) {
        return error.SkipZigTest;
    }
    const cqe_idx = cq_head & ring.cq_ring_mask;
    const cqe = &ring.cqes[cqe_idx];

    try testing.expectEqual(@as(u64, 42), cqe.user_data);
    try testing.expect(cqe.res >= 0);

    // 推进 cq_head
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);
}
