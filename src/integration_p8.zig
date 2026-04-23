// src/integration_p8.zig
// ZigClaw V2.4 Phase8 | WriteV to temporary file via real io_uring
const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");

test "Phase8: WriteV to /tmp/zigclaw_p8_test via real io_uring" {
    // 1. 创建 Ring
    const ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    // 2. 打开临时文件（创建 + 截断 + 读写）
    const test_path: [*:0]const u8 = "/tmp/zigclaw_p8_test";
    const file_fd = try io_uring.Syscall.openat(
        -100, // AT_FDCWD
        test_path,
        io_uring.Syscall.O_RDWR | io_uring.Syscall.O_CREAT | io_uring.Syscall.O_TRUNC,
        0o644, // 文件权限
    );
    defer io_uring.Syscall.close(@intCast(file_fd));

    // 3. 准备写缓冲区 + iovec
    var write_buf: [4096]u8 = undefined;
    @memset(&write_buf, 0xDE); // 数据特征字节

    var iovec = io_uring.Iovec{
        .iov_base = @ptrCast(&write_buf),
        .iov_len = 4096,
    };

    // 4. 填写 SQE
    const sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    const idx = sq_tail & io_uring.SQ_MASK;
    ring.sq_entries[idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.WriteV),
        .flags = 0,
        .ioprio = 0,
        .fd = file_fd,
        .off = 0,
        .addr = @intFromPtr(&iovec),
        .len = 1, // 1 个 iovec
        .__pad1 = 0,
        .user_data = 8888,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    // 写入 sq_array 告诉内核 SQE[idx] 有效
    ring.sq_array[idx] = idx;

    // 安全推进 sq_tail
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
    try testing.expectEqual(@as(u64, 8888), cqe.user_data);
    try testing.expectEqual(@as(i32, 4096), cqe.res);

    // 推进 cq_head
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);
}
