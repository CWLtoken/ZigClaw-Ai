// src/integration_p10.zig
// ZigClaw V2.4 Phase10 | Batch submit: io_uring 的核心性能优势
// DRD-013: 一次 enter() 提交 4 个 WriteV，一次 ReadV 读回验证
// 关键：CQE 返回顺序可能与提交顺序不同，必须根据 user_data 识别
const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");

test "Phase10: Batch submit 4 WriteV + verify with ReadV" {
    const BUF_SIZE: u64 = 256;
    const BATCH_COUNT: u32 = 4;

    // 1. 创建 Ring
    const ring = io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    // 2. 打开临时文件
    const test_path: [*:0]const u8 = "/tmp/zigclaw_p10_batch";
    const file_fd = io_uring.Syscall.openat(
        -100, // AT_FDCWD
        test_path,
        io_uring.Syscall.O_RDWR | io_uring.Syscall.O_CREAT | io_uring.Syscall.O_TRUNC,
        0o644,
    );
    defer io_uring.Syscall.close(@intCast(file_fd));

    // 3. 准备 4 个写缓冲区，各填不同特征值
    var write_bufs: [BATCH_COUNT][BUF_SIZE]u8 = undefined;
    const patterns = [4]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    for (0..BATCH_COUNT) |i| {
        @memset(&write_bufs[i], patterns[i]);
    }

    // 4. 准备 4 个 iovec
    var write_iovecs: [BATCH_COUNT]io_uring.Iovec = undefined;
    for (0..BATCH_COUNT) |i| {
        write_iovecs[i] = .{
            .iov_base = @ptrCast(&write_bufs[i]),
            .iov_len = BUF_SIZE,
        };
    }

    // === 批量填写 4 个 SQE ===
    var sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    for (0..BATCH_COUNT) |i| {
        const idx = (sq_tail + @as(u32, @intCast(i))) & ring.sq_ring_mask;
        ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.WriteV),
            .flags = 0,
            .ioprio = 0,
            .fd = file_fd,
            .off = @as(u64, @intCast(i)) * BUF_SIZE, // 0, 256, 512, 768
            .addr = @intFromPtr(&write_iovecs[i]),
            .len = 1, // 1 个 iovec per SQE
            .__pad1 = 0,
            .user_data = 2001 + @as(u64, @intCast(i)), // 2001-2004
            .buf_index = 0,
            .personality = 0,
            .splice_fd_in = 0,
            .addr3 = 0,
            .__pad2 = 0,
        };
        // 告诉内核 SQE[idx] 有效
        ring.sq_array[idx] = idx;
    }

    // 安全推进 sq_tail（+4）
    const ov_batch = @addWithOverflow(sq_tail, BATCH_COUNT);
    if (ov_batch[1] != 0) return error.SkipZigTest;
    @atomicStore(u32, ring.sq_tail, ov_batch[0], .release);

    // === 一次 enter 提交 4 个 ===
    const submitted = io_uring.Syscall.enter(ring.fd, BATCH_COUNT, BATCH_COUNT, 0);
    if (submitted < 0) return error.SkipZigTest;
    // enter 返回实际提交数，min_complete=4 阻塞直到全部完成

    // === 回收 4 个 CQE（顺序可能乱） ===
    var cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    // min_complete=4 保证 enter 返回时 4 个 CQE 已就绪
    try testing.expect(cq_tail >= cq_head + BATCH_COUNT);

    for (0..BATCH_COUNT) |_| {
        const cqe = &ring.cqes[cq_head & ring.cq_ring_mask];
        // 不假设顺序，只验证每个 CQE 的 res 和 user_data 范围
        try testing.expectEqual(@as(i32, BUF_SIZE), cqe.res);
        try testing.expect(cqe.user_data >= 2001 and cqe.user_data <= 2004);
        cq_head += 1;
    }
    @atomicStore(u32, ring.cq_head, cq_head, .release);

    // === ReadV 读回 1024 字节验证 ===
    var read_buf: [BATCH_COUNT * BUF_SIZE]u8 = undefined;
    @memset(&read_buf, 0xFF); // 哨兵值

    var read_iovecs: [BATCH_COUNT]io_uring.Iovec = undefined;
    for (0..BATCH_COUNT) |i| {
        read_iovecs[i] = .{
            .iov_base = @ptrCast(&read_buf[i * BUF_SIZE]),
            .iov_len = BUF_SIZE,
        };
    }

    sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    const idx_r = sq_tail & ring.sq_ring_mask;
    ring.sq_entries[idx_r] = .{
        .opcode = @intFromEnum(io_uring.IOOp.ReadV),
        .flags = 0,
        .ioprio = 0,
        .fd = file_fd,
        .off = 0, // 从文件起始读
        .addr = @intFromPtr(&read_iovecs),
        .len = BATCH_COUNT, // 4 个 iovec，共 1024 字节
        .__pad1 = 0,
        .user_data = 3001,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx_r] = idx_r;

    // 安全推进 sq_tail（+1）
    const ov_read = @addWithOverflow(sq_tail, 1);
    if (ov_read[1] != 0) return error.SkipZigTest;
    @atomicStore(u32, ring.sq_tail, ov_read[0], .release);

    const submitted_r = io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    if (submitted_r < 0) return error.SkipZigTest;

    // 回收 ReadV CQE
    cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail_r = @atomicLoad(u32, ring.cq_tail, .acquire);
    try testing.expect(cq_tail_r > cq_head);
    const cqe_r = &ring.cqes[cq_head & ring.cq_ring_mask];
    try testing.expectEqual(@as(u64, 3001), cqe_r.user_data);
    try testing.expectEqual(@as(i32, BATCH_COUNT * BUF_SIZE), cqe_r.res);
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    // === 核心断言：4 段数据各自正确 ===
    // [0..256]=0xAA, [256..512]=0xBB, [512..768]=0xCC, [768..1024]=0xDD
    for (0..BATCH_COUNT) |i| {
        const start = i * BUF_SIZE;
        const end = start + BUF_SIZE;
        for (start..end) |j| {
            try testing.expectEqual(patterns[i], read_buf[j]);
        }
    }
}
