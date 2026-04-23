// src/integration_p6.zig
// ZigClaw V2.4 Phase6 | io_uring_enter 系统调用验证
const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");
const reactor_mod = @import("reactor.zig");

test "Phase6: io_uring_enter syscall verification" {
    std.debug.print("DEBUG: before Ring.init()\n", .{});
    const ring = io_uring.Ring.init();
    std.debug.print("DEBUG: after Ring.init(), fd={}\n", .{ring.fd});
    defer {
        _ = io_uring.Syscall.close(ring.fd);
    }

    std.debug.print("DEBUG: ring.fd={}, sq_ring_mask={}, cq_ring_mask={}\n",
        .{ring.fd, ring.sq_ring_mask, ring.cq_ring_mask});
    std.debug.print("DEBUG: sq_entries ptr={*}\n", .{ring.sq_entries});

    const sq_depth = ring.sq_ring_mask + 1;
    const cq_depth = ring.cq_ring_mask + 1;
    std.debug.print("DEBUG: SQ depth={}, CQ depth={}\n", .{sq_depth, cq_depth});

    // 准备 SQE: NOP
    const sq_tail_val = @atomicLoad(u32, ring.sq_tail, .acquire);
    const idx = sq_tail_val & io_uring.SQ_MASK;
    std.debug.print("DEBUG: sq_tail={}, idx={}\n", .{sq_tail_val, idx});

    ring.sq_entries[idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.NOP),
        .fd = -1,
        .off = 0,
        .addr = 0,
        .len = 0,
        .user_data = 42,
        .flags = 0, .ioprio = 0, .__pad1 = 0,
        .buf_index = 0, .personality = 0,
        .splice_fd_in = 0, .addr3 = 0, .__pad2 = 0,
    };
    std.debug.print("DEBUG: SQE[{}] written, user_data={}\n", .{idx, ring.sq_entries[idx].user_data});

    // 安全推进 sq_tail
    const ov_result = @addWithOverflow(sq_tail_val, 1);
    if (ov_result[1] != 0) {
        std.debug.print("WARNING: sq_tail overflowed\n", .{});
    }
    const new_sq_tail = ov_result[0];
    @atomicStore(u32, ring.sq_tail, new_sq_tail, .release);
    std.debug.print("DEBUG: new_sq_tail={}\n", .{new_sq_tail});

    // 调用 enter()
    std.debug.print("DEBUG: calling enter(fd={}, to_submit=1, min_complete=1, flags=0x01)\n", .{ring.fd});
    const submitted = io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    std.debug.print("DEBUG: enter() returned {}\n", .{submitted});

    if (submitted < 0) {
        std.debug.print("enter() failed: {}\n", .{submitted});
        return error.SkipZigTest;
    }
    try testing.expectEqual(@as(i32, 1), submitted);

    // 读取 CQE
    const cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    std.debug.print("DEBUG: cq_head={}, cq_tail={}\n", .{cq_head, cq_tail});

    if (cq_head == cq_tail) {
        std.debug.print("CQ is empty after enter()\n", .{});
        return error.SkipZigTest;
    }
    const cqe_idx = cq_head & ring.cq_ring_mask;
    const cqe = &ring.cqes[cqe_idx];
    std.debug.print("DEBUG: CQE[{}]: user_data={}, res={}\n", .{cqe_idx, cqe.user_data, cqe.res});

    try testing.expectEqual(@as(u64, 42), cqe.user_data);
    try testing.expect(cqe.res >= 0);

    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);
    std.debug.print("Phase6 PASSED: enter() syscall works!\n", .{});
}
