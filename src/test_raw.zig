const std = @import("std");
const std_os = std.os.linux;

pub fn main() !void {
    const SetupParams = extern struct {
        sq_entries: u32, cq_entries: u32, flags: u32,
        sq_thread_cpu: u32, sq_thread_idle: u32, features: u32, wq_fd: u32,
        resv: [3]u32,
        sq_off: extern struct {
            head: u32, tail: u32, ring_mask: u32, ring_entries: u32,
            flags: u32, dropped: u32, array: u32, resv1: u32, user_addr: u64,
        },
        cq_off: extern struct {
            head: u32, tail: u32, ring_mask: u32, ring_entries: u32,
            overflow: u32, cqes: u32, flags: u32, resv1: u32, user_addr: u64,
        },
    };
    var params = std.mem.zeroes(SetupParams);
    const setup_rc = std_os.syscall2(.io_uring_setup, @as(usize, 1024), @intFromPtr(&params));
    const fd: u32 = @intCast(setup_rc);
    defer _ = std_os.syscall1(.close, @as(usize, fd));

    std.debug.print("fd={}, sq_entries={}, cq_entries={}, features=0x{x}\n", .{ fd, params.sq_entries, params.cq_entries, params.features });

    // Check if IORING_FEAT_NATIVE_WORKERS or other features are present
    // features bit 0 = IORING_FEAT_SINGLE_MMAP
    // features bit 1 = IORING_FEAT_NODROP
    // features bit 2 = IORING_FEAT_NATIVE_WORKERS
    // features bit 3 = IORING_FEAT_RSRC_TAGS
    std.debug.print("sq_off: head={} tail={} ring_mask={} ring_entries={} flags={} dropped={} array={}\n", .{
        params.sq_off.head, params.sq_off.tail, params.sq_off.ring_mask,
        params.sq_off.ring_entries, params.sq_off.flags, params.sq_off.dropped, params.sq_off.array,
    });
    std.debug.print("cq_off: head={} tail={} ring_mask={} ring_entries={} overflow={} cqes={}\n", .{
        params.cq_off.head, params.cq_off.tail, params.cq_off.ring_mask,
        params.cq_off.ring_entries, params.cq_off.overflow, params.cq_off.cqes,
    });

    // Normal chain test: WriteV(valid_fd) -> FSync(valid_fd)
    const sq_ring_size = (params.sq_off.array + params.sq_entries * @sizeOf(u32) + 4095) & ~@as(usize, 4095);
    const cq_ring_size = (params.cq_off.cqes + params.cq_entries * 16 + 4095) & ~@as(usize, 4095);
    const sqes_size = params.sq_entries * 64;

    const sq_ptr = std_os.syscall6(.mmap, @as(usize, 0), sq_ring_size, @as(usize, 3), @as(usize, 0x8001), @as(usize, fd), @as(usize, 0));
    const cq_ptr = std_os.syscall6(.mmap, @as(usize, 0), cq_ring_size, @as(usize, 3), @as(usize, 0x8001), @as(usize, fd), sq_ring_size);
    const sqes_raw = std_os.syscall6(.mmap, @as(usize, 0), sqes_size, @as(usize, 3), @as(usize, 0x01), @as(usize, fd), @as(usize, 0x10000000));

    std.debug.print("mmap: sq=0x{x} cq=0x{x} sqes=0x{x}\n", .{ sq_ptr, cq_ptr, sqes_raw });

    const sq_tail: *u32 = @ptrFromInt(sq_ptr + params.sq_off.tail);
    const sq_array: [*]u32 = @ptrFromInt(sq_ptr + params.sq_off.array);
    const sq_ring_mask = @as(*u32, @ptrFromInt(sq_ptr + params.sq_off.ring_mask)).*;

    std.debug.print("initial sq_tail={}, sq_ring_mask={}\n", .{ sq_tail.*, sq_ring_mask });

    // Open a real file for normal chain test
    const file_fd = std_os.syscall4(.openat, @as(usize, 0xFFFFFFFFFFFFFF9C), @intFromPtr(@as([*:0]const u8, "/tmp/zigclaw_p12_raw")), @as(usize, 0x242), @as(usize, 0o644));
    const ffd: i32 = @intCast(file_fd);
    std.debug.print("file_fd={}\n", .{ffd});
    defer _ = std_os.syscall1(.close, @as(usize, @as(u32, @bitCast(ffd))));

    // Test NORMAL chain: WriteV(valid_fd) -> FSync(valid_fd)
    var write_buf: [1024]u8 = undefined;
    @memset(&write_buf, 0x77);
    var iovec = extern struct { iov_base: [*]u8, iov_len: usize }{
        .iov_base = @ptrCast(&write_buf),
        .iov_len = 1024,
    };

    const tail = sq_tail.*;
    const idx0 = tail & sq_ring_mask;
    const idx1 = (tail + 1) & sq_ring_mask;

    // SQE0: WriteV + IOSQE_IO_LINK
    const sqe0: [*]u8 = @ptrFromInt(sqes_raw + idx0 * 64);
    @memset(sqe0[0..64], 0);
    sqe0[0] = 2; // IORING_OP_WRITEV
    sqe0[1] = 2; // IOSQE_IO_LINK
    @as(*i32, @ptrFromInt(@intFromPtr(sqe0) + 4)).* = ffd;
    @as(*usize, @ptrFromInt(@intFromPtr(sqe0) + 16)).* = @intFromPtr(&iovec);
    @as(*u32, @ptrFromInt(@intFromPtr(sqe0) + 24)).* = 1;
    @as(*u64, @ptrFromInt(@intFromPtr(sqe0) + 32)).* = 7001;

    // SQE1: FSync (no IO_LINK)
    const sqe1: [*]u8 = @ptrFromInt(sqes_raw + idx1 * 64);
    @memset(sqe1[0..64], 0);
    sqe1[0] = 3; // IORING_OP_FSYNC
    @as(*i32, @ptrFromInt(@intFromPtr(sqe1) + 4)).* = ffd;
    @as(*u64, @ptrFromInt(@intFromPtr(sqe1) + 32)).* = 7002;

    sq_array[idx0] = idx0;
    sq_array[idx1] = idx1;
    sq_tail.* = tail + 2;

    const submitted = std_os.syscall5(.io_uring_enter, @as(usize, fd), @as(usize, 2), @as(usize, 2), @as(usize, 1), @as(usize, 0));
    std.debug.print("normal chain submitted={}\n", .{submitted});

    const cq_head: *u32 = @ptrFromInt(cq_ptr + params.cq_off.head);
    const cq_tail_p: *u32 = @ptrFromInt(cq_ptr + params.cq_off.tail);
    const cq_ring_mask = @as(*u32, @ptrFromInt(cq_ptr + params.cq_off.ring_mask)).*;

    for (0..2) |_| {
        const head = cq_head.*;
        const ctail = cq_tail_p.*;
        if (head < ctail) {
            const cqe_ud: *u64 = @ptrFromInt(cq_ptr + params.cq_off.cqes + (head & cq_ring_mask) * 16);
            const cqe_res: *i32 = @ptrFromInt(cq_ptr + params.cq_off.cqes + (head & cq_ring_mask) * 16 + 8);
            std.debug.print("CQE: user_data={} res={}\n", .{ cqe_ud.*, cqe_res.* });
            cq_head.* = head + 1;
        }
    }

    // Now test BROKEN chain: WriteV(fd=-1) -> FSync(fd=-1)
    const tail2 = sq_tail.*;
    const idx2 = tail2 & sq_ring_mask;
    const idx3 = (tail2 + 1) & sq_ring_mask;

    const sqe2: [*]u8 = @ptrFromInt(sqes_raw + idx2 * 64);
    @memset(sqe2[0..64], 0);
    sqe2[0] = 2; // IORING_OP_WRITEV
    sqe2[1] = 2; // IOSQE_IO_LINK
    @as(*i32, @ptrFromInt(@intFromPtr(sqe2) + 4)).* = -1;
    @as(*usize, @ptrFromInt(@intFromPtr(sqe2) + 16)).* = @intFromPtr(&iovec);
    @as(*u32, @ptrFromInt(@intFromPtr(sqe2) + 24)).* = 1;
    @as(*u64, @ptrFromInt(@intFromPtr(sqe2) + 32)).* = 8001;

    const sqe3: [*]u8 = @ptrFromInt(sqes_raw + idx3 * 64);
    @memset(sqe3[0..64], 0);
    sqe3[0] = 3; // IORING_OP_FSYNC
    @as(*i32, @ptrFromInt(@intFromPtr(sqe3) + 4)).* = -1;
    @as(*u64, @ptrFromInt(@intFromPtr(sqe3) + 32)).* = 8002;

    sq_array[idx2] = idx2;
    sq_array[idx3] = idx3;
    sq_tail.* = tail2 + 2;

    const submitted2 = std_os.syscall5(.io_uring_enter, @as(usize, fd), @as(usize, 2), @as(usize, 2), @as(usize, 1), @as(usize, 0));
    std.debug.print("broken chain submitted={}\n", .{submitted2});

    for (0..2) |_| {
        const head = cq_head.*;
        const ctail = cq_tail_p.*;
        if (head < ctail) {
            const cqe_ud: *u64 = @ptrFromInt(cq_ptr + params.cq_off.cqes + (head & cq_ring_mask) * 16);
            const cqe_res: *i32 = @ptrFromInt(cq_ptr + params.cq_off.cqes + (head & cq_ring_mask) * 16 + 8);
            std.debug.print("CQE: user_data={} res={}\n", .{ cqe_ud.*, cqe_res.* });
            cq_head.* = head + 1;
        }
    }
}
