// src/reactor.zig
// ZigClaw V2.4 Phase5 | SPSC硬件隔离层 | buf_ptr血液指针孔位 | Zig 0.16 物理级守卫
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

    pub fn poll(self: *Reactor) Event {
        const sq_tail = @atomicLoad(u32, &self.ring.sq_tail, .acquire);
        const sq_head = @atomicLoad(u32, &self.ring.sq_head, .acquire);

        if (sq_tail -% sq_head == 0) return .Idle;

        const idx = sq_head & io_uring.SQ_MASK;
        const entry = &self.ring.sq_entries[idx];

        @atomicStore(u32, &self.ring.sq_head, sq_head + 1, .release);

        return Event{
            .IoComplete = .{
                .user_data = entry.user_data,
                .result = entry.buf_len,
                .buf_ptr = entry.buf_ptr,
            },
        };
    }

    comptime {
        if (@offsetOf(Reactor, "ring") != 0) {
            @compileError("ZC-FATAL: Reactor's only field must be ring at offset 0");
        }
        if (@sizeOf(Reactor) != @sizeOf(io_uring.Ring)) {
            @compileError("ZC-FATAL: Reactor must be exactly the size of io_uring.Ring, no extra fields");
        }

        const dummy_ring = io_uring.Ring.init();
        _ = dummy_ring.sq_head;
        _ = dummy_ring.sq_tail;
        _ = dummy_ring.sq_entries;
        _ = io_uring.SQ_MASK;
        if ((io_uring.SQ_DEPTH & (io_uring.SQ_DEPTH - 1)) != 0) {
            @compileError("ZC-FATAL: SQ_DEPTH must be power of 2, mask operation is invalid");
        }

        var dummy_u32: u32 = 0;
        @atomicStore(u32, &dummy_u32, 1, .release);
        _ = @atomicLoad(u32, &dummy_u32, .acquire);

        if (@sizeOf(Event.IoComplete) != 24) {
            @compileError("ZC-FATAL: IoComplete must be exactly 24 bytes after buf_ptr addition");
        }

        if (@TypeOf(io_uring.Ring.sq_head) != u32 or @TypeOf(io_uring.Ring.sq_tail) != u32) {
            @compileError("ZC-FATAL: sq_head/sq_tail must be u32 for atomic operations");
        }
    }
};
