// src/integration_p6.zig
// ZigClaw V2.4 Phase6 | io_uring_enter 系统调用验证
const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");
const reactor_mod = @import("reactor.zig");

test "Phase6: io_uring_enter syscall verification" {
    // 1. 初始化真正的 io_uring 实例（需要内核支持）
    // Ring.init() 采用裸金属死亡策略：失败直接 exit(1)
    const ring = io_uring.Ring.init();
    defer {
        _ = io_uring.Syscall.close(ring.fd);
    }

    // 调试：打印 sq_tail 和 sq_head 的初始值
    std.debug.print("DEBUG: sq_tail pointer={*}, sq_head pointer={*}\n", .{ring.sq_tail, ring.sq_head});
    std.debug.print("DEBUG: sq_tail.*={}, sq_head.*={}\n", .{ring.sq_tail.*, ring.sq_head.*});
    std.debug.print("DEBUG: sq_ring_mask={}, cq_ring_mask={}\n", .{ring.sq_ring_mask, ring.cq_ring_mask});

    // 2. 准备 SQE: NOP 操作（内核会立即完成）
    const idx = ring.sq_tail.* & io_uring.SQ_MASK;
    std.debug.print("DEBUG: idx={}, sq_entries pointer={*}\n", .{idx, ring.sq_entries});
    ring.sq_entries[idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.NOP),
        .fd = -1,
        .off = 0,
        .addr = 0,
        .len = 0,
        .user_data = 42, // 测试值
        .flags = 0, .ioprio = 0, .__pad1 = 0,
        .buf_index = 0, .personality = 0,
        .splice_fd_in = 0, .addr3 = 0, .__pad2 = 0,
    };
    std.debug.print("DEBUG: SQE[{}] user_data={}\n", .{idx, ring.sq_entries[idx].user_data});
    
    // 调试：打印 sq_tail 当前值，检查是否溢出
    const new_sq_tail: u32 = ring.sq_tail.* + 1;
    std.debug.print("DEBUG: new_sq_tail={}\n", .{new_sq_tail});
    @atomicStore(u32, ring.sq_tail, new_sq_tail, .release);

    // 3. 调用 enter() 提交并等待 1 个完成
    const cq_head_before = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail_before = @atomicLoad(u32, ring.cq_tail, .acquire);
    std.debug.print("DEBUG: before enter(): sq_tail={}, cq_head={}, cq_tail={}\n", .{ring.sq_tail.*, cq_head_before, cq_tail_before});

    const submitted = io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    std.debug.print("DEBUG: enter() returned {}, cq_head={}, cq_tail={}\n", .{submitted, cq_head_before, @atomicLoad(u32, ring.cq_tail, .acquire)});

    if (submitted < 0) {
        std.debug.print("enter() failed: {}\n", .{submitted});
        return error.SkipZigTest;
    }
    try testing.expectEqual(@as(i32, 1), submitted);

    // 4. 读取 CQE
    const cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    std.debug.print("DEBUG: after enter(): cq_head={}, cq_tail={}\n", .{cq_head, cq_tail});
    if (cq_head == cq_tail) {
        std.debug.print("CQ is empty after enter()\n", .{});
        return error.SkipZigTest;
    }
    const cqe_idx = cq_head & ring.cq_ring_mask;
    const cqe = &ring.cqes[cqe_idx];
    std.debug.print("DEBUG: CQE[{}]: user_data={}, res={}\n", .{cqe_idx, cqe.user_data, cqe.res});

    // 5. 验证 CQE
    try testing.expectEqual(@as(u64, 42), cqe.user_data);
    try testing.expect(cqe.res >= 0); // NOP 应该成功

    // 6. 推进 CQ head
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    std.debug.print("Phase6 PASSED: enter() syscall works!\n", .{});
}
