const std = @import("std");
const io_uring = @import("io_uring.zig");

pub fn main() !void {
    const ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    var write_buf: [1024]u8 = undefined;
    @memset(&write_buf, 0x88);
    var iovec = io_uring.Iovec{ .iov_base = @ptrCast(&write_buf), .iov_len = 1024 };

    const sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);

    // SQE 0: WriteV, fd=-1, IOSQE_IO_LINK
    const idx_w = sq_tail & ring.sq_ring_mask;
    ring.sq_entries[idx_w] = .{
        .opcode = @intFromEnum(io_uring.IOOp.WriteV),
        .flags = @intCast(io_uring.IOSQE_IO_LINK),
        .ioprio = 0,
        .fd = -1,
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

    // SQE 1: FSync, fd=-1
    const idx_f = (sq_tail + 1) & ring.sq_ring_mask;
    ring.sq_entries[idx_f] = .{
        .opcode = @intFromEnum(io_uring.IOOp.FSync),
        .flags = 0,
        .ioprio = 0,
        .fd = -1,
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

    const ov = @addWithOverflow(sq_tail, @as(u32, 2));
    @atomicStore(u32, ring.sq_tail, ov[0], .release);

    const submitted = try io_uring.Syscall.enter(ring.fd, 2, 2, 0);

    std.debug.print("submitted={}\n", .{submitted});

    var cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    for (0..2) |_| {
        const cqe = &ring.cqes[cq_head & ring.cq_ring_mask];
        std.debug.print("CQE: user_data={} res={}\n", .{ cqe.user_data, cqe.res });
        cq_head += 1;
    }
    @atomicStore(u32, ring.cq_head, cq_head, .release);
}
