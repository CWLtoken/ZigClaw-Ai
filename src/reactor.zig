// src/reactor.zig
// ZigClaw V2.4 Phase5 | SPSC hardware isolation | buf_ptr blood pointer | Zig 0.16 typeInfo guard
const io_uring = @import("io_uring.zig");

pub const Event = union(enum) {
    IoComplete: struct {
        user_data: u64,
        result: u32,
        buf_ptr: ?*anyopaque,
    },
    Idle,
};

pub const Reactor = struct {
    ring: io_uring.Ring,

    pub fn init(ring: io_uring.Ring) Reactor {
        return .{ .ring = ring };
    }

    // ZC-3-02: 提交 SQ 给内核，等待 CQ 完成
    pub fn submit(self: *Reactor, to_submit: u32, min_complete: u32) i32 {
        return io_uring.Syscall.enter(self.ring.fd, to_submit, min_complete, 0);
    }

    pub fn poll(self: *Reactor) Event {
        // real io_uring: application reads CQ only
        const cq_head = @atomicLoad(u32, self.ring.cq_head, .acquire);
        const cq_tail = @atomicLoad(u32, self.ring.cq_tail, .acquire);

        if (cq_head == cq_tail) return .Idle;

        const idx = cq_head & self.ring.cq_ring_mask;
        const cqe = &self.ring.cqes[idx];

        // advance CQ head, notify kernel this CQE is consumed
        @atomicStore(u32, self.ring.cq_head, cq_head + 1, .release);

        // ZC-2-04: decode user_data as *IoRequest (stage 3 architecture)
        const req = @as(*io_uring.IoRequest, @ptrFromInt(cqe.user_data));
        return Event{
            .IoComplete = .{
                .user_data = req.stream_id,
                .result = @as(u32, @bitCast(cqe.res)),
                .buf_ptr = req.buf_ptr,
            },
        };
    }

    comptime {
        // guard 1: IoComplete layout check via @typeInfo index
        const IoComplete = @typeInfo(Event).@"union".fields[0].type;
        const fields = @typeInfo(IoComplete).@"struct".fields;
        var computed: usize = 0;
        var max_align: usize = 1;
        for (fields) |f| {
            const fa = @alignOf(f.type);
            if (fa > max_align) max_align = fa;
            const mis = computed % fa;
            if (mis != 0) computed += fa - mis;
            computed += @sizeOf(f.type);
        }
        const tail = computed % max_align;
        if (tail != 0) computed += max_align - tail;
        if (computed != @sizeOf(IoComplete)) {
            @compileError("ZC-FATAL: layout algorithm diverges from compiler");
        }
        if (@sizeOf(IoComplete) != 24) {
            @compileError("ZC-FATAL: IoComplete must be 24 bytes, field tampering detected");
        }

        // guard 2: SQ_DEPTH must be comptime_int and power of 2
        if (@TypeOf(io_uring.SQ_DEPTH) != comptime_int) {
            @compileError("ZC-FATAL: SQ_DEPTH must be comptime_int");
        }
        if (io_uring.SQ_DEPTH <= 0) {
            @compileError("ZC-FATAL: SQ_DEPTH must be > 0");
        }
        if ((io_uring.SQ_DEPTH & (io_uring.SQ_DEPTH - 1)) != 0) {
            @compileError("ZC-FATAL: SQ_DEPTH must be power of 2");
        }

        // guard 3: atomic ops syntax check
        var dummy_u32: u32 = 0;
        @atomicStore(u32, &dummy_u32, 1, .release);
        _ = @atomicLoad(u32, &dummy_u32, .acquire);

        _ = io_uring.SQ_MASK;
    }

};
