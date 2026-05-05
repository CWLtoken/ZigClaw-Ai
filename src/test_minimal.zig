const std = @import("std");
const os = std.os.linux;

pub fn main() !void {
    const SetupParams = extern struct {
        sq_entries: u32, cq_entries: u32, flags: u32,
        sq_thread_cpu: u32, sq_thread_idle: u32, features: u32, wq_fd: u32,
        resv: [3]u32,
        sq_off: extern struct { head: u32, tail: u32, ring_mask: u32, ring_entries: u32, flags: u32, dropped: u32, array: u32, resv1: u32, user_addr: u64 },
        cq_off: extern struct { head: u32, tail: u32, ring_mask: u32, ring_entries: u32, overflow: u32, cqes: u32, flags: u32, resv1: u32, user_addr: u64 },
    };
    var p = std.mem.zeroes(SetupParams);
    const setup_rc = os.syscall2(.io_uring_setup, 32, @intFromPtr(&p));
    const fd: u32 = @intCast(setup_rc);
    defer _ = os.syscall1(.close, @as(usize, fd));
    std.debug.print("fd={} entries={} features=0x{x}\n", .{fd, p.sq_entries, p.features});

    const sqsz: usize = (@as(usize, p.sq_off.array) + @as(usize, p.sq_entries) * 4 + 4095) & ~@as(usize, 4095);
    const cqsz: usize = (@as(usize, p.cq_off.cqes) + @as(usize, p.cq_entries) * 16 + 4095) & ~@as(usize, 4095);

    // SQ ring: IORING_OFF_SQ_RING = 0
    const sqr_rc = os.syscall6(.mmap, 0, sqsz, 3, 0x8001, @as(usize, fd), 0);
    // CQ ring: IORING_OFF_CQ_RING = 0x8000000
    const cqr_rc = os.syscall6(.mmap, 0, cqsz, 3, 0x8001, @as(usize, fd), 0x8000000);
    // SQEs: IORING_OFF_SQES = 0x10000000
    const sqes_rc = os.syscall6(.mmap, 0, @as(usize, p.sq_entries) * 64, 3, 1, @as(usize, fd), 0x10000000);

    std.debug.print("sqr=0x{x} cqr=0x{x} sqes=0x{x}\n", .{sqr_rc, cqr_rc, sqes_rc});

    const sqr = sqr_rc;
    const cqr = cqr_rc;
    const sqes = sqes_rc;

    const sq_tail: *u32 = @ptrFromInt(sqr + p.sq_off.tail);
    const sq_arr: [*]u32 = @ptrFromInt(sqr + p.sq_off.array);
    const sq_mask: u32 = @as(*u32, @ptrFromInt(sqr + p.sq_off.ring_mask)).*;
    const cq_head: *u32 = @ptrFromInt(cqr + p.cq_off.head);
    const cq_tail_p: *u32 = @ptrFromInt(cqr + p.cq_off.tail);
    const cq_mask: u32 = @as(*u32, @ptrFromInt(cqr + p.cq_off.ring_mask)).*;

    std.debug.print("sq_mask={} cq_mask={}\n", .{sq_mask, cq_mask});

    var write_buf: [1024]u8 = undefined;
    @memset(&write_buf, 0x88);
    const Iovec = extern struct { iov_base: [*]u8, iov_len: usize };
    var iov = Iovec{ .iov_base = &write_buf, .iov_len = 1024 };

    const t = sq_tail.*;
    const iw = t & sq_mask;
    const ifx = (t + 1) & sq_mask;

    // SQE0: WriteV + IOSQE_IO_LINK, fd=-1
    const sqe0_base = sqes + iw * 64;
    const sqe0: [*]u8 = @ptrFromInt(sqe0_base);
    @memset(sqe0[0..64], 0);
    sqe0[0] = 2; // IORING_OP_WRITEV
    sqe0[1] = 2; // IOSQE_IO_LINK
    @as(*i32, @ptrFromInt(sqe0_base + 4)).* = -1;
    @as(*u64, @ptrFromInt(sqe0_base + 16)).* = @intFromPtr(&iov);
    @as(*u32, @ptrFromInt(sqe0_base + 24)).* = 1;
    @as(*u64, @ptrFromInt(sqe0_base + 32)).* = 8001;

    // SQE1: FSync, fd=-1
    const sqe1_base = sqes + ifx * 64;
    const sqe1: [*]u8 = @ptrFromInt(sqe1_base);
    @memset(sqe1[0..64], 0);
    sqe1[0] = 3; // IORING_OP_FSYNC
    @as(*i32, @ptrFromInt(sqe1_base + 4)).* = -1;
    @as(*u64, @ptrFromInt(sqe1_base + 32)).* = 8002;

    sq_arr[iw] = iw;
    sq_arr[ifx] = ifx;

    @atomicStore(u32, sq_tail, t + 2, .release);

    const sub_rc = os.syscall6(.io_uring_enter, @as(usize, fd), 2, 2, 1, 0, 0);
    std.debug.print("submitted={}\n", .{sub_rc});
    std.debug.print("cq_head={} cq_tail={}\n", .{cq_head.*, cq_tail_p.*});

    for (0..2) |i| {
        const h = cq_head.*;
        if (h != cq_tail_p.*) {
            const base = cqr + p.cq_off.cqes + (h & cq_mask) * 16;
            const ud: u64 = @as(*u64, @ptrFromInt(base)).*;
            const res: i32 = @as(*i32, @ptrFromInt(base + 8)).*;
            std.debug.print("CQE[{}]: ud={} res={}\n", .{i, ud, res});
            cq_head.* = h + 1;
        }
    }
}
