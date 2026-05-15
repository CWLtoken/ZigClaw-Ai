// src/file_store.zig
// 存储层 | Layer: Storage
// DRD-059 V6: 存储外置适配 — 文件版 FileStore
//
// 设计原则（显性直白）：
//   - io_uring 异步文件 I/O
//   - 提交 ≠ 完成：每次操作显式等待 CQE
//   - 零堆分配：所有缓冲区在栈上
//   - 无中间封装：直接操作 SQE/CQE

const mem = @import("std").mem;
const linux = @import("std").os.linux;
const log = @import("std").log;
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");
const heat_pool = @import("heat_pool.zig");

const DEFAULT_PATH: [*:0]const u8 = "/tmp/zigclaw_heat_pool.bin";

// ============================================================================
// FileStore 结构体
// ============================================================================

pub const FileStore = struct {
    path: [*:0]const u8,

    pub fn init(path: [*:0]const u8) FileStore {
        return .{ .path = path };
    }

    /// 保存热度池到文件
    /// 显式流程：open → 构造 SQE → flush → 等 CQE → close
    pub fn saveHeatPool(self: *const FileStore, pool: *heat_pool.HeatPool, r: *reactor.Reactor) !void {
        const fd = try io_uring.Syscall.openat(
            -100,
            self.path,
            io_uring.Syscall.O_CREAT | io_uring.Syscall.O_RDWR | io_uring.Syscall.O_TRUNC,
            0o644,
        );
        errdefer io_uring.Syscall.close(@intCast(fd));

        const heats_bytes = @constCast(mem.asBytes(&pool.heats));

        // 显性直白：直接提交 write SQE，不通过 prepare_write 中转
        const sqe_count = try self.submit_write_chunks(r, fd, heats_bytes);

        // 提交到内核
        try r.flush();

        // 显性直白：等待所有 CQE 完成（提交 ≠ 完成）
        try wait_cqe(r, sqe_count);

        io_uring.Syscall.close(@intCast(fd));
    }

    /// 从文件加载热度池
    pub fn loadHeatPool(self: *const FileStore, r: *reactor.Reactor) !heat_pool.HeatPool {
        const fd = io_uring.Syscall.openat(
            -100,
            self.path,
            io_uring.Syscall.O_RDONLY,
            0,
        ) catch |err| {
            if (err == io_uring.SyscallError.OpenFailed) {
                return error.FileNotFound;
            }
            return err;
        };
        errdefer io_uring.Syscall.close(@intCast(fd));

        var pool = heat_pool.HeatPool.init();
        const heats_bytes = @constCast(mem.asBytes(&pool.heats));

        const sqe_count = try self.submit_read_chunks(r, fd, heats_bytes);
        try r.flush();
        try wait_cqe(r, sqe_count);

        io_uring.Syscall.close(@intCast(fd));

        return pool;
    }

    /// 删除持久化文件（测试清理用）
    pub fn deleteFile(self: *const FileStore) void {
        _ = linux.syscall3(
            .unlinkat,
            @as(usize, @bitCast(@as(i64, @as(i32, -100)))),
            @intFromPtr(self.path),
            0,
        );
    }

    // --------------------------------------------------------------------------
    // 显性直白：直接操作 SQE
    // --------------------------------------------------------------------------

    fn submit_write_chunks(self: *const FileStore, r: *reactor.Reactor, fd: i32, data: []const u8) !u32 {
        _ = self;
        var offset: u64 = 0;
        var count: u32 = 0;
        while (offset < data.len) {
            const idx: usize = @intCast(offset);
            const remaining = data.len - idx;
            const chunk: u32 = if (remaining < 4096) @intCast(remaining) else 4096;

            // 直接写 SQE 到 ring buffer
            const end: usize = idx + @as(usize, chunk);
            try sqe_write(r, fd, data[idx..end], offset);

            offset += chunk;
            count += 1;
        }
        return count;
    }

    fn submit_read_chunks(self: *const FileStore, r: *reactor.Reactor, fd: i32, data: []u8) !u32 {
        _ = self;
        var offset: u64 = 0;
        var count: u32 = 0;
        while (offset < data.len) {
            const idx: usize = @intCast(offset);
            const remaining = data.len - idx;
            const chunk: u32 = if (remaining < 4096) @intCast(remaining) else 4096;

            const end: usize = idx + @as(usize, chunk);
            try sqe_read(r, fd, data[idx..end], offset);

            offset += chunk;
            count += 1;
        }
        return count;
    }
};

// ============================================================================
// 零封装 SQE 辅助函数
// ============================================================================

/// 直接写一个 WRITE SQE 到 ring buffer
/// 无 IoRequest 中转，user_data 用缓冲区指针本身
fn sqe_write(r: *reactor.Reactor, fd: i32, buf: []const u8, offset: u64) !void {
    const sq_tail = @atomicLoad(u32, r.ring.sq_tail, .acquire);
    const sq_head = @atomicLoad(u32, r.ring.sq_head, .acquire);
    if (sq_tail - sq_head >= io_uring.SQ_DEPTH) {
        try r.flush();
    }
    const idx = sq_tail & r.ring.sq_ring_mask;

    r.ring.sq_entries[idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.Write),
        .flags = 0,
        .ioprio = 0,
        .fd = fd,
        .off = offset,
        .addr = @intFromPtr(buf.ptr),
        .len = @as(u32, @intCast(buf.len)),
        .__pad1 = 0,
        .user_data = @intFromPtr(buf.ptr), // 显性直白：指针即标识
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    r.ring.sq_array[idx] = idx;
    @atomicStore(u32, r.ring.sq_tail, sq_tail + 1, .release);

    r.pending_sqe_count += 1;
    if (r.pending_sqe_count >= 8) { // BATCH_THRESHOLD default
        try r.flush();
    }
}

/// 直接写一个 READ SQE 到 ring buffer
fn sqe_read(r: *reactor.Reactor, fd: i32, buf: []u8, offset: u64) !void {
    const sq_tail = @atomicLoad(u32, r.ring.sq_tail, .acquire);
    const sq_head = @atomicLoad(u32, r.ring.sq_head, .acquire);
    if (sq_tail - sq_head >= io_uring.SQ_DEPTH) {
        try r.flush();
    }
    const idx = sq_tail & r.ring.sq_ring_mask;

    r.ring.sq_entries[idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.Read),
        .flags = 0,
        .ioprio = 0,
        .fd = fd,
        .off = offset,
        .addr = @intFromPtr(buf.ptr),
        .len = @as(u32, @intCast(buf.len)),
        .__pad1 = 0,
        .user_data = @intFromPtr(buf.ptr),
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    r.ring.sq_array[idx] = idx;
    @atomicStore(u32, r.ring.sq_tail, sq_tail + 1, .release);

    r.pending_sqe_count += 1;
    if (r.pending_sqe_count >= 8) { // BATCH_THRESHOLD default
        try r.flush();
    }
}

/// 等待指定数量的 CQE 完成
/// 提交 ≠ 完成：必须显式 poll
/// 安全限制：最大 poll 次数 = count * 100，防止无限忙等
fn wait_cqe(r: *reactor.Reactor, count: u32) !void {
    var completed: u32 = 0;
    var max_polls: u32 = count * 100;
    while (completed < count) {
        if (max_polls == 0) {
            log.err("wait_cqe: exceeded max polls ({d})", .{count * 100});
            return error.IoUringTimeout;
        }
        max_polls -= 1;
        const ev = r.poll();
        switch (ev) {
            .IoComplete => |cqe| {
                if (cqe.result < 0) {
                    log.err("io_uring CQE error: res={d}", .{cqe.result});
                    return error.IoUringCqeError;
                }
                completed += 1;
            },
            .Idle => {}, // 继续等待
        }
    }
}
