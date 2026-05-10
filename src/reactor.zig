// src/reactor.zig
// 执行层 | Layer: Execution
// ZigClaw V2.4 Phase5 | SPSC hardware isolation | buf_ptr blood pointer | Zig 0.16 typeInfo guard
const io_uring = @import("io_uring.zig");
const log = @import("std").log;

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
    pending_sqe_count: u32 = 0,

    /// 批量提交阈值：累积到这么多 SQE 时自动 submit
    const BATCH_THRESHOLD: u32 = 8;

    // ====== 军规：flush 调用位置 ======
    // 1. prepare_recv / prepare_send 中 >= BATCH_THRESHOLD 时自动 flush
    // 2. 进入 io_uring_wait_cqe / poll 前，必须 flush
    // 3. 其它地方禁止直接调用 flush，除非有特殊性能调优理由
    // ==================================

    pub fn init(ring: io_uring.Ring) Reactor {
        return .{ .ring = ring, .pending_sqe_count = 0 };
    }

    /// 延迟提交：只在需要时将 SQE 刷出到内核
    /// 调用方在以下情况必须调用：
    ///   1. 进入 io_uring_wait_cqe / poll 前
    ///   2. accumulated SQE 达到 BATCH_THRESHOLD
    pub fn flush(self: *Reactor) io_uring.SyscallError!void {
        if (self.pending_sqe_count > 0) {
            _ = try io_uring.Syscall.enter(self.ring.fd, self.pending_sqe_count, 0, 0);
            self.pending_sqe_count = 0;
        }
    }

    /// 提交 SQ 给内核，等待 CQ 完成（兼容旧接口）
    pub fn submit(self: *Reactor, to_submit: u32, min_complete: u32) io_uring.SyscallError!u32 {
        return io_uring.Syscall.enter(self.ring.fd, to_submit, min_complete, 0);
    }

    /// 向 SQ 提交一个 RECV 请求（延迟提交策略）
    pub fn prepare_recv(self: *Reactor, fd: i32, iovec: *io_uring.Iovec, io_req: *io_uring.IoRequest) io_uring.SyscallError!void {
        const sq_tail = @atomicLoad(u32, self.ring.sq_tail, .acquire);
        const idx = sq_tail & self.ring.sq_ring_mask;

        self.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.ReadV),
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off = 0,
            .addr = @intFromPtr(iovec),
            .len = 1,
            .__pad1 = 0,
            .user_data = @intFromPtr(io_req),
            .buf_index = 0,
            .personality = 0,
            .splice_fd_in = 0,
            .addr3 = 0,
            .__pad2 = 0,
        };
        self.ring.sq_array[idx] = idx;
        @atomicStore(u32, self.ring.sq_tail, sq_tail + 1, .release);

        self.pending_sqe_count += 1;
        if (self.pending_sqe_count >= BATCH_THRESHOLD) {
            try self.flush();
        }
    }

    /// 向 SQ 提交一个 SEND 请求（延迟提交策略）
    pub fn prepare_send(self: *Reactor, fd: i32, iovec: *io_uring.Iovec, io_req: *io_uring.IoRequest) io_uring.SyscallError!void {
        const sq_tail = @atomicLoad(u32, self.ring.sq_tail, .acquire);
        const idx = sq_tail & self.ring.sq_ring_mask;

        self.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.WriteV),
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off = 0,
            .addr = @intFromPtr(iovec),
            .len = 1,
            .__pad1 = 0,
            .user_data = @intFromPtr(io_req),
            .buf_index = 0,
            .personality = 0,
            .splice_fd_in = 0,
            .addr3 = 0,
            .__pad2 = 0,
        };
        self.ring.sq_array[idx] = idx;
        @atomicStore(u32, self.ring.sq_tail, sq_tail + 1, .release);

        self.pending_sqe_count += 1;
        if (self.pending_sqe_count >= BATCH_THRESHOLD) {
            try self.flush();
        }
    }

    /// 从 CQ 获取完成事件（自动 flush 挂起的 SQE）
    pub fn poll(self: *Reactor) Event {
        // 进入 poll 前，先 flush 所有挂起的 SQE
        // 军规：flush 失败时继续执行（poll 仍可返回 Idle），但必须显式处理
        self.flush() catch |flush_err| {
            // flush 失败意味着内核提交失败，记录后继续
            // 不 panic，不 unreachable，不空 catch
            log.warn("Reactor.poll: flush failed: {s}", .{@errorName(flush_err)});
        };

        const cq_head = @atomicLoad(u32, self.ring.cq_head, .acquire);
        const cq_tail = @atomicLoad(u32, self.ring.cq_tail, .acquire);

        if (cq_head == cq_tail) return .Idle;

        const idx = cq_head & self.ring.cq_ring_mask;
        const cqe = &self.ring.cqes[idx];

        @atomicStore(u32, self.ring.cq_head, cq_head + 1, .release);

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
