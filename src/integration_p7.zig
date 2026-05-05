// src/integration_p7.zig
// ZigClaw V2.4 Phase7 | ReadV from /dev/zero via real io_uring
const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");

test "Phase7: ReadV from /dev/zero via real io_uring" {
    // 1. 创建 Ring
    const ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    // 2. 打开 /dev/zero
    const dev_zero: [*:0]const u8 = "/dev/zero";
    const file_fd = try io_uring.Syscall.openat(
        -100, // AT_FDCWD
        dev_zero,
        io_uring.Syscall.O_RDONLY,
        0,
    );
    defer io_uring.Syscall.close(@intCast(file_fd));

    // 3. 准备读缓冲区 + iovec
    var read_buf: [4096]u8 = undefined;
    // 先填入 0xAA 作为哨兵值，验证被内核覆盖为零
    @memset(&read_buf, 0xAA);

    var iovec = io_uring.Iovec{
        .iov_base = @ptrCast(&read_buf),
        .iov_len = 4096,
    };

    // 4. 填写 SQE
    const sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    const idx = sq_tail & io_uring.SQ_MASK;
    ring.sq_entries[idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.ReadV),
        .flags = 0,
        .ioprio = 0,
        .fd = file_fd,
        .off = 0,
        .addr = @intFromPtr(&iovec),
        .len = 1, // 1 个 iovec
        .__pad1 = 0,
        .user_data = 7777,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    // 写入 sq_array 告诉内核 SQE[idx] 有效
    ring.sq_array[idx] = idx;

    // 推进 sq_tail
    const ov_result = @addWithOverflow(sq_tail, 1);
    if (ov_result[1] != 0) return error.SkipZigTest;
    @atomicStore(u32, ring.sq_tail, ov_result[0], .release);

    // 5. 提交给内核
    const submitted = try io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    try testing.expectEqual(@as(u32, 1), submitted);

    // 6. 回收 CQE
    const cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cq_tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    try testing.expect(cq_tail > cq_head);
    const cqe_idx = cq_head & ring.cq_ring_mask;
    const cqe = &ring.cqes[cqe_idx];

    // 7. 验证
    try testing.expectEqual(@as(u64, 7777), cqe.user_data);
    try testing.expectEqual(@as(i32, 4096), cqe.res);

    // 验证缓冲区被内核覆盖为零（哨兵值 0xAA 应该消失）
    for (&read_buf) |byte| {
        try testing.expectEqual(@as(u8, 0), byte);
    }

    // 推进 cq_head
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);
}
