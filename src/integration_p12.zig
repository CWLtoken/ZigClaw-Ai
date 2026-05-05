// src/integration_p12.zig
// ZigClaw V2.4 Phase12 | IOSQE_IO_LINK: 链式 SQE 事务性 I/O
// DRD-016: 正常链(WriteV→FSync) + 断裂链(WriteV fail→FSync cancelled)
// 关键：链断裂时后续 SQE 仍产生 CQE，res=-ECANCELED(-125)
const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");

test "Phase12: IOSQE_IO_LINK normal chain (WriteV -> FSync)" {
    const BUF_SIZE: u32 = 1024;

    const ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    const test_path: [*:0]const u8 = "/tmp/zigclaw_p12_link";
    const file_fd = try io_uring.Syscall.openat(
        -100, // AT_FDCWD
        test_path,
        io_uring.Syscall.O_RDWR | io_uring.Syscall.O_CREAT | io_uring.Syscall.O_TRUNC,
        0o644,
    );
    defer io_uring.Syscall.close(@intCast(file_fd));

    var write_buf: [BUF_SIZE]u8 = undefined;
    @memset(&write_buf, 0x77);
    var iovec = io_uring.Iovec{ .iov_base = @ptrCast(&write_buf), .iov_len = BUF_SIZE };

    // === 链式提交：WriteV -> FSync ===
    const sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);

    // SQE 0: WriteV，设置 IOSQE_IO_LINK 链接到下一个
    const idx_w = sq_tail & ring.sq_ring_mask;
    ring.sq_entries[idx_w] = .{
        .opcode = @intFromEnum(io_uring.IOOp.WriteV),
        .flags = @intCast(io_uring.IOSQE_IO_LINK), // 链接到 SQE 1
        .ioprio = 0,
        .fd = file_fd,
        .off = 0,
        .addr = @intFromPtr(&iovec),
        .len = 1,
        .__pad1 = 0,
        .user_data = 7001,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx_w] = idx_w;

    // SQE 1: FSync，不设置 IOSQE_IO_LINK（链尾）
    const idx_f = (sq_tail + 1) & ring.sq_ring_mask;
    ring.sq_entries[idx_f] = .{
        .opcode = @intFromEnum(io_uring.IOOp.FSync),
        .flags = 0, // 链尾，不设置 IO_LINK
        .ioprio = 0,
        .fd = file_fd,
        .off = 0,
        .addr = 0,
        .len = 0,
        .__pad1 = 0,
        .user_data = 7002,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx_f] = idx_f;

    // 安全推进 sq_tail（+2）
    const ov = @addWithOverflow(sq_tail, @as(u32, 2));
    if (ov[1] != 0) return error.SkipZigTest;
    @atomicStore(u32, ring.sq_tail, ov[0], .release);

    const submitted = try io_uring.Syscall.enter(ring.fd, 2, 2, 0);
    try testing.expectEqual(@as(u32, 2), submitted);

    // === 回收 2 个 CQE（顺序可能乱） ===
    var cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    try testing.expect(cq_tail >= cq_head + 2);

    var write_ok = false;
    var fsync_ok = false;
    for (0..2) |_| {
        const cqe = &ring.cqes[cq_head & ring.cq_ring_mask];
        if (cqe.user_data == 7001) {
            try testing.expectEqual(@as(i32, @intCast(BUF_SIZE)), cqe.res);
            write_ok = true;
        } else if (cqe.user_data == 7002) {
            try testing.expectEqual(@as(i32, 0), cqe.res);
            fsync_ok = true;
        }
        cq_head += 1;
    }
    @atomicStore(u32, ring.cq_head, cq_head, .release);

    try testing.expect(write_ok);
    try testing.expect(fsync_ok);
}

test "Phase12b: IOSQE_IO_LINK broken chain (WriteV fail -> FSync cancelled)" {
    const BUF_SIZE: u32 = 1024;

    const ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    var write_buf: [BUF_SIZE]u8 = undefined;
    @memset(&write_buf, 0x88);
    var iovec = io_uring.Iovec{ .iov_base = @ptrCast(&write_buf), .iov_len = BUF_SIZE };

    // === 断裂链：WriteV(fd=-1) -> FSync ===
    const sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);

    // SQE 0: WriteV，fd=-1 故意失败
    const idx_w = sq_tail & ring.sq_ring_mask;
    ring.sq_entries[idx_w] = .{
        .opcode = @intFromEnum(io_uring.IOOp.WriteV),
        .flags = @intCast(io_uring.IOSQE_IO_LINK),
        .ioprio = 0,
        .fd = -1, // 无效 fd，故意 EBADF
        .off = 0,
        .addr = @intFromPtr(&iovec),
        .len = 1,
        .__pad1 = 0,
        .user_data = 8001,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx_w] = idx_w;

    // SQE 1: FSync，会被取消（res=-ECANCELED）
    const idx_f = (sq_tail + 1) & ring.sq_ring_mask;
    ring.sq_entries[idx_f] = .{
        .opcode = @intFromEnum(io_uring.IOOp.FSync),
        .flags = 0, // 链尾
        .ioprio = 0,
        .fd = -1, // 即使无效也无所谓，不会执行
        .off = 0,
        .addr = 0,
        .len = 0,
        .__pad1 = 0,
        .user_data = 8002,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx_f] = idx_f;

    // 安全推进 sq_tail（+2）
    const ov = @addWithOverflow(sq_tail, @as(u32, 2));
    if (ov[1] != 0) return error.SkipZigTest;
    @atomicStore(u32, ring.sq_tail, ov[0], .release);

    const submitted = try io_uring.Syscall.enter(ring.fd, 2, 2, 0);
    try testing.expectEqual(@as(u32, 2), submitted);

    // === 回收 2 个 CQE ===
    var cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    try testing.expect(cq_tail >= cq_head + 2);

    var write_failed = false;
    var fsync_cancelled = false;
    for (0..2) |_| {
        const cqe = &ring.cqes[cq_head & ring.cq_ring_mask];
        if (cqe.user_data == 8001) {
            // WriteV 应该失败，res = -EBADF = -9
            try testing.expectEqual(@as(i32, -9), cqe.res);
            write_failed = true;
        } else if (cqe.user_data == 8002) {
            // FSync 应该被取消，res = -ECANCELED = -125
            try testing.expectEqual(@as(i32, -io_uring.ECANCELED), cqe.res);
            fsync_cancelled = true;
        }
        cq_head += 1;
    }
    @atomicStore(u32, ring.cq_head, cq_head, .release);

    try testing.expect(write_failed);
    try testing.expect(fsync_cancelled);
}
