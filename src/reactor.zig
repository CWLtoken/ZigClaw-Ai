// src/reactor.zig
// 执行层 | Layer: Execution
// ZigClaw V2.4 Phase5 | SPSC hardware isolation | buf_ptr blood pointer | Zig 0.16 typeInfo guard
const io_uring = @import("io_uring.zig");
const log = @import("std").log;

pub const Event = union(enum) {
    IoComplete: struct {
        user_data: u64,
        result: i32,
        buf_ptr: ?*anyopaque,
    },
    Idle,
};

pub const Reactor = struct {
    ring: io_uring.Ring,
    pending_sqe_count: u32 = 0,

    /// 批量提交阈值：累积到这么多 SQE 时自动 submit
    /// 可通过 build.zig 编译期配置：zig build -Dbatch_threshold=16
    const BATCH_THRESHOLD: u32 = if (@hasDecl(@import("build_options"), "batch_threshold"))
        @import("build_options").batch_threshold
    else
        8;

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
            // 军规：显式错误处理，禁止隐式 try
            if (io_uring.Syscall.enter(self.ring.fd, self.pending_sqe_count, 0, 0)) |_|
            {
                self.pending_sqe_count = 0;
            } else |err|
            {
                return err;
            }
        }
    }

    /// 提交 SQ 给内核，等待 CQ 完成（兼容旧接口）
    pub fn submit(self: *Reactor, to_submit: u32, min_complete: u32) io_uring.SyscallError!u32 {
        return io_uring.Syscall.enter(self.ring.fd, to_submit, min_complete, 0);
    }

    /// 向 SQ 提交一个 RECV 请求（延迟提交策略）
    pub fn prepare_recv(self: *Reactor, fd: i32, iovec: *io_uring.Iovec, io_req: *io_uring.IoRequest) io_uring.SyscallError!void {
        // SQ 满溢防护：检查内核 sq_head，确保有可用槽位
        const sq_head = @atomicLoad(u32, self.ring.sq_head, .acquire);
        const sq_tail = @atomicLoad(u32, self.ring.sq_tail, .acquire);
        if (sq_tail - sq_head >= io_uring.SQ_DEPTH) {
            // SQ 已满，先 flush 再重试
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
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
        // 军规：显式错误处理，禁止隐式 try
        if (self.pending_sqe_count >= BATCH_THRESHOLD) {
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
    }

    /// 向 SQ 提交一个 ACCEPT 请求（延迟提交策略）
    pub fn prepare_accept(self: *Reactor, listen_fd: i32, addr: ?*io_uring.Syscall.SockAddrIn, addrlen: ?*u32, io_req: *io_uring.IoRequest) io_uring.SyscallError!void {
        const sq_head = @atomicLoad(u32, self.ring.sq_head, .acquire);
        const sq_tail = @atomicLoad(u32, self.ring.sq_tail, .acquire);
        if (sq_tail - sq_head >= io_uring.SQ_DEPTH) {
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
        const idx = sq_tail & self.ring.sq_ring_mask;

        self.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.Accept),
            .flags = 0,
            .ioprio = 0,
            .fd = listen_fd,
            .off = 0,
            .addr = if (addr) |a| @intFromPtr(a) else 0,
            .len = if (addrlen) |al| @as(u32, @intCast(@intFromPtr(al))) else 0,
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
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
    }

    /// 向 SQ 提交一个 SEND 请求（延迟提交策略）
    pub fn prepare_send(self: *Reactor, fd: i32, iovec: *io_uring.Iovec, io_req: *io_uring.IoRequest) io_uring.SyscallError!void {
        // SQ 满溢防护：检查内核 sq_head，确保有可用槽位
        const sq_head = @atomicLoad(u32, self.ring.sq_head, .acquire);
        const sq_tail = @atomicLoad(u32, self.ring.sq_tail, .acquire);
        if (sq_tail - sq_head >= io_uring.SQ_DEPTH) {
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
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
        // 军规：显式错误处理，禁止隐式 try
        if (self.pending_sqe_count >= BATCH_THRESHOLD) {
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
    }

    /// 向 SQ 提交一个 WRITE 请求（延迟提交策略）
    /// 用于 io_uring 异步文件写入（IORING_OP_WRITE）
    pub fn prepare_write(self: *Reactor, fd: i32, iovec: *const io_uring.Iovec, offset: u64, io_req: *io_uring.IoRequest) io_uring.SyscallError!void {
        const sq_head = @atomicLoad(u32, self.ring.sq_head, .acquire);
        const sq_tail = @atomicLoad(u32, self.ring.sq_tail, .acquire);
        if (sq_tail - sq_head >= io_uring.SQ_DEPTH) {
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
        const idx = sq_tail & self.ring.sq_ring_mask;

        self.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.Write),
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off = offset,
            .addr = @intFromPtr(iovec.iov_base),
            .len = @as(u32, @intCast(iovec.iov_len)),
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
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
    }

    /// 向 SQ 提交一个 READ 请求（延迟提交策略）
    /// 用于 io_uring 异步文件读取（IORING_OP_READ）
    pub fn prepare_read(self: *Reactor, fd: i32, iovec: *const io_uring.Iovec, offset: u64, io_req: *io_uring.IoRequest) io_uring.SyscallError!void {
        const sq_head = @atomicLoad(u32, self.ring.sq_head, .acquire);
        const sq_tail = @atomicLoad(u32, self.ring.sq_tail, .acquire);
        if (sq_tail - sq_head >= io_uring.SQ_DEPTH) {
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
        const idx = sq_tail & self.ring.sq_ring_mask;

        self.ring.sq_entries[idx] = .{
            .opcode = @intFromEnum(io_uring.IOOp.Read),
            .flags = 0,
            .ioprio = 0,
            .fd = fd,
            .off = offset,
            .addr = @intFromPtr(iovec.iov_base),
            .len = @as(u32, @intCast(iovec.iov_len)),
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
            if (self.flush()) |_|
            {
                // flush 成功，继续
            } else |err|
            {
                return err;
            }
        }
    }

    /// 从 CQ 获取完成事件（自动 flush 挂起的 SQE）
    pub fn poll(self: *Reactor) Event {
        // 进入 poll 前，先 flush 所有挂起的 SQE
        // 军规：flush 失败时继续执行（poll 仍可返回 Idle），但必须显式处理
        if (self.flush()) |_|
        {
            // flush 成功，继续
        } else |_|
        {
            // flush 失败意味着内核提交失败，记录后继续
            // 不 panic，不 unreachable，不空 catch
            // SEC-7: 不暴露内核错误名称，使用通用描述
            log.warn("Reactor.poll: kernel submit failed", .{});
        }

        const cq_head = @atomicLoad(u32, self.ring.cq_head, .acquire);
        const cq_tail = @atomicLoad(u32, self.ring.cq_tail, .acquire);

        if (cq_head == cq_tail) return .Idle;

        const idx = cq_head & self.ring.cq_ring_mask;
        const cqe = &self.ring.cqes[idx];

        // 安全校验：user_data 必须非零且指针对齐
        if (cqe.user_data == 0) {
            // SEC-7: 不暴露内部指针值，仅记录通用描述
            log.warn("Reactor.poll: invalid CQE received", .{});
            @atomicStore(u32, self.ring.cq_head, cq_head + 1, .release);
            return .Idle;
        }
        const req_ptr = @as(*io_uring.IoRequest, @ptrFromInt(cqe.user_data));
        if (@intFromPtr(req_ptr) % @alignOf(io_uring.IoRequest) != 0) {
            // SEC-7: 不暴露指针对齐地址，仅记录通用描述
            log.warn("Reactor.poll: misaligned CQE received", .{});
            @atomicStore(u32, self.ring.cq_head, cq_head + 1, .release);
            return .Idle;
        }

        // 递增 cq_head，标记 CQE 已被消费
        @atomicStore(u32, self.ring.cq_head, cq_head + 1, .release);

        return Event{
            .IoComplete = .{
                .user_data = req_ptr.stream_id,
                .result = cqe.res,
                .buf_ptr = req_ptr.buf_ptr,
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
