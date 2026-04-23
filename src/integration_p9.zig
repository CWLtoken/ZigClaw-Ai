// src/integration_p9.zig
// ZigClaw V2.4 Phase9 | WriteV + ReadV data consistency loop
// DRD-012: 证明写入磁盘的数据可以原样读回，验证 io_uring 在同一 fd 上的状态连续性
const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");

test "Phase9: WriteV then ReadV data consistency loop" {
    // 1. 创建 Ring
    const ring = io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    // 2. 打开临时文件（创建 + 截断 + 读写）
    const test_path: [*:0]const u8 = "/tmp/zigclaw_p9_loop";
    const file_fd = io_uring.Syscall.openat(
        -100, // AT_FDCWD
        test_path,
        io_uring.Syscall.O_RDWR | io_uring.Syscall.O_CREAT | io_uring.Syscall.O_TRUNC,
        0o644,
    );
    defer io_uring.Syscall.close(@intCast(file_fd));

    // 3. 准备缓冲区
    var write_buf: [4096]u8 = undefined;
    var read_buf: [4096]u8 = undefined;
    @memset(&read_buf, 0xFF); // 哨兵值

    // 递增特征序列：比纯 0xDE 更能验证偏移和顺序
    for (0..4096) |i| {
        write_buf[i] = @intCast(i % 256);
    }

    var write_iovec = io_uring.Iovec{
        .iov_base = @ptrCast(&write_buf),
        .iov_len = 4096,
    };
    var read_iovec = io_uring.Iovec{
        .iov_base = @ptrCast(&read_buf),
        .iov_len = 4096,
    };

    // === 提交 WriteV ===
    var sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    var idx = sq_tail & io_uring.SQ_MASK;
    ring.sq_entries[idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.WriteV),
        .flags = 0,
        .ioprio = 0,
        .fd = file_fd,
        .off = 0, // 绝对偏移 0
        .addr = @intFromPtr(&write_iovec),
        .len = 1, // 1 个 iovec
        .__pad1 = 0,
        .user_data = 1001,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx] = idx; // 告诉内核 SQE[idx] 有效

    // 安全推进 sq_tail
    const ov1 = @addWithOverflow(sq_tail, 1);
    if (ov1[1] != 0) return error.SkipZigTest;
    @atomicStore(u32, ring.sq_tail, ov1[0], .release);

    // 提交给内核
    const submitted_w = io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    if (submitted_w < 0) return error.SkipZigTest;
    try testing.expectEqual(@as(i32, 1), submitted_w);

    // === 回收 WriteV CQE ===
    var cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail_w = @atomicLoad(u32, ring.cq_tail, .acquire);
    try testing.expect(cq_tail_w > cq_head);
    const cqe_w = &ring.cqes[cq_head & ring.cq_ring_mask];

    try testing.expectEqual(@as(u64, 1001), cqe_w.user_data);
    try testing.expectEqual(@as(i32, 4096), cqe_w.res);

    // 推进 cq_head，为下一个 CQE 做准备
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    // === 提交 ReadV ===
    sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    idx = sq_tail & io_uring.SQ_MASK;
    ring.sq_entries[idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.ReadV),
        .flags = 0,
        .ioprio = 0,
        .fd = file_fd,
        .off = 0, // 绝对偏移 0，读回刚才写的数据
        .addr = @intFromPtr(&read_iovec),
        .len = 1, // 1 个 iovec
        .__pad1 = 0,
        .user_data = 1002,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx] = idx; // 告诉内核 SQE[idx] 有效

    // 安全推进 sq_tail
    const ov2 = @addWithOverflow(sq_tail, 1);
    if (ov2[1] != 0) return error.SkipZigTest;
    @atomicStore(u32, ring.sq_tail, ov2[0], .release);

    // 提交给内核
    const submitted_r = io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    if (submitted_r < 0) return error.SkipZigTest;
    try testing.expectEqual(@as(i32, 1), submitted_r);

    // === 回收 ReadV CQE ===
    cq_head = @atomicLoad(u32, ring.cq_head, .acquire); // 重新加载，基于上一次 +1 的状态
    const cq_tail_r = @atomicLoad(u32, ring.cq_tail, .acquire);
    try testing.expect(cq_tail_r > cq_head);
    const cqe_r = &ring.cqes[cq_head & ring.cq_ring_mask];

    try testing.expectEqual(@as(u64, 1002), cqe_r.user_data);
    try testing.expectEqual(@as(i32, 4096), cqe_r.res);

    // 推进 cq_head
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    // === 核心断言：数据一致性 ===
    // 逐字节比对：write_buf[i] == read_buf[i]
    for (0..4096) |i| {
        try testing.expectEqual(write_buf[i], read_buf[i]);
    }
}
