// src/integration_p11.zig
// ZigClaw V2.4 Phase11 | Fixed Buffer Pool: IORING_REGISTER_BUFFERS
// DRD-015: 固定缓冲区池注册 → WriteFixed/ReadFixed → 数据一致性验证
// 关键：addr 是已注册缓冲区的绝对地址（不是偏移量），buf_index 选择池中缓冲区
const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");

test "Phase11: ReadFixed/WriteFixed with registered buffer pool" {
    const BUF_SIZE: u32 = 4096;
    const POOL_SIZE: u32 = 2;

    // 1. 创建 Ring
    const ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    // 2. 打开临时文件
    const test_path: [*:0]const u8 = "/tmp/zigclaw_p11_fixed";
    const file_fd = try io_uring.Syscall.openat(
        -100, // AT_FDCWD
        test_path,
        io_uring.Syscall.O_RDWR | io_uring.Syscall.O_CREAT | io_uring.Syscall.O_TRUNC,
        0o644,
    );
    defer io_uring.Syscall.close(@intCast(file_fd));

    // === 准备固定缓冲区池 ===
    var buf0: [BUF_SIZE]u8 = undefined;
    var buf1: [BUF_SIZE]u8 = undefined;
    @memset(&buf0, 0x11);
    @memset(&buf1, 0x22);

    var iovecs: [POOL_SIZE]io_uring.Iovec = .{
        .{
            .iov_base = @ptrCast(&buf0),
            .iov_len = BUF_SIZE,
        },
        .{
            .iov_base = @ptrCast(&buf1),
            .iov_len = BUF_SIZE,
        },
    };

    // === 注册缓冲区池 ===
    try io_uring.Syscall.register_buffers(ring.fd, &iovecs, POOL_SIZE);
    // 必须先 unregister 才能释放缓冲区，defer 中 catch {} 忽略注销错误
    defer io_uring.Syscall.unregister_buffers(ring.fd) catch {};

    // === 批量 WriteFixed：buf0 写文件偏移 0，buf1 写文件偏移 4096 ===
    var sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);

    // SQE 0: WriteFixed, buf_index=0, off=0
    const idx_w0 = sq_tail & ring.sq_ring_mask;
    ring.sq_entries[idx_w0] = .{
        .opcode = @intFromEnum(io_uring.IOOp.WriteFixed),
        .flags = 0,
        .ioprio = 0,
        .fd = file_fd,
        .off = 0, // 文件偏移
        .addr = @intFromPtr(&buf0), // 已注册缓冲区绝对地址
        .len = BUF_SIZE,
        .__pad1 = 0,
        .user_data = 5001,
        .buf_index = 0, // 使用 buf0
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx_w0] = idx_w0;

    // SQE 1: WriteFixed, buf_index=1, off=4096
    const idx_w1 = (sq_tail + 1) & ring.sq_ring_mask;
    ring.sq_entries[idx_w1] = .{
        .opcode = @intFromEnum(io_uring.IOOp.WriteFixed),
        .flags = 0,
        .ioprio = 0,
        .fd = file_fd,
        .off = BUF_SIZE, // 文件偏移 4096
        .addr = @intFromPtr(&buf1), // 已注册缓冲区绝对地址
        .len = BUF_SIZE,
        .__pad1 = 0,
        .user_data = 5002,
        .buf_index = 1, // 使用 buf1
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx_w1] = idx_w1;

    // 安全推进 sq_tail（+2）
    const ov_w = @addWithOverflow(sq_tail, POOL_SIZE);
    if (ov_w[1] != 0) return error.SkipZigTest;
    @atomicStore(u32, ring.sq_tail, ov_w[0], .release);

    const submitted_w = try io_uring.Syscall.enter(ring.fd, POOL_SIZE, POOL_SIZE, 0);
    try testing.expectEqual(@as(u32, POOL_SIZE), submitted_w);

    // 回收 2 个 CQE
    var cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail_w = @atomicLoad(u32, ring.cq_tail, .acquire);
    try testing.expect(cq_tail_w >= cq_head + POOL_SIZE);

    for (0..POOL_SIZE) |_| {
        const cqe = &ring.cqes[cq_head & ring.cq_ring_mask];
        try testing.expectEqual(@as(i32, @intCast(BUF_SIZE)), cqe.res);
        cq_head += 1;
    }
    @atomicStore(u32, ring.cq_head, cq_head, .release);

    // === 清空缓冲区（验证读回确实从文件加载） ===
    @memset(&buf0, 0xFF);
    @memset(&buf1, 0xFF);

    // === 批量 ReadFixed：buf0 读文件偏移 0，buf1 读文件偏移 4096 ===
    sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);

    const idx_r0 = sq_tail & ring.sq_ring_mask;
    ring.sq_entries[idx_r0] = .{
        .opcode = @intFromEnum(io_uring.IOOp.ReadFixed),
        .flags = 0,
        .ioprio = 0,
        .fd = file_fd,
        .off = 0, // 文件偏移
        .addr = @intFromPtr(&buf0), // 已注册缓冲区绝对地址
        .len = BUF_SIZE,
        .__pad1 = 0,
        .user_data = 6001,
        .buf_index = 0, // 读入 buf0
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx_r0] = idx_r0;

    const idx_r1 = (sq_tail + 1) & ring.sq_ring_mask;
    ring.sq_entries[idx_r1] = .{
        .opcode = @intFromEnum(io_uring.IOOp.ReadFixed),
        .flags = 0,
        .ioprio = 0,
        .fd = file_fd,
        .off = BUF_SIZE, // 文件偏移 4096
        .addr = @intFromPtr(&buf1), // 已注册缓冲区绝对地址
        .len = BUF_SIZE,
        .__pad1 = 0,
        .user_data = 6002,
        .buf_index = 1, // 读入 buf1
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[idx_r1] = idx_r1;

    // 安全推进 sq_tail（+2）
    const ov_r = @addWithOverflow(sq_tail, POOL_SIZE);
    if (ov_r[1] != 0) return error.SkipZigTest;
    @atomicStore(u32, ring.sq_tail, ov_r[0], .release);

    const submitted_r = try io_uring.Syscall.enter(ring.fd, POOL_SIZE, POOL_SIZE, 0);
    try testing.expectEqual(@as(u32, POOL_SIZE), submitted_r);

    // 回收 2 个 CQE
    cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail_r = @atomicLoad(u32, ring.cq_tail, .acquire);
    try testing.expect(cq_tail_r >= cq_head + POOL_SIZE);

    for (0..POOL_SIZE) |_| {
        const cqe = &ring.cqes[cq_head & ring.cq_ring_mask];
        try testing.expectEqual(@as(i32, @intCast(BUF_SIZE)), cqe.res);
        cq_head += 1;
    }
    @atomicStore(u32, ring.cq_head, cq_head, .release);

    // === 核心断言：固定缓冲区池数据正确 ===
    for (0..BUF_SIZE) |i| {
        try testing.expectEqual(@as(u8, 0x11), buf0[i]);
        try testing.expectEqual(@as(u8, 0x22), buf1[i]);
    }
}
