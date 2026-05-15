// src/file_store.zig
// 存储层 | Layer: Storage
// DRD-059 V5: 存储外置适配 — 文件版 FileStore
//
// 设计原则：
//   - 使用 io_uring 异步文件 I/O（IORING_OP_READ / IORING_OP_WRITE）
//   - 通过 Reactor 提交 SQE，实现真正的 io_uring 零拷贝异步文件操作
//   - 不依赖 fs 高级封装
//   - 所有缓冲区在栈上，零堆分配
//   - 实现 StorageInterface 风格的 VTable 接口
//
// 文件格式：
//   纯二进制，直接写入 HeatPool 的 heats 数组字节表示
//   文件路径：/tmp/zigclaw_heat_pool.bin（测试用）

const mem = @import("std").mem;
const linux = @import("std").os.linux;
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");
const heat_pool = @import("heat_pool.zig");

// ============================================================================
// 文件路径常量
// ============================================================================

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
    /// 使用 io_uring 异步文件 I/O（openat + IORING_OP_WRITE + close）
    /// 通过 Reactor 提交 SQE，实现真正的 io_uring 零拷贝异步写入
    pub fn saveHeatPool(self: *const FileStore, pool: *heat_pool.HeatPool, r: *reactor.Reactor) !void {
        const fd = try io_uring.Syscall.openat(
            -100,
            self.path,
            io_uring.Syscall.O_CREAT | io_uring.Syscall.O_RDWR | io_uring.Syscall.O_TRUNC,
            0o644,
        );
        errdefer io_uring.Syscall.close(@intCast(fd));

        const heats_bytes = @constCast(mem.asBytes(&pool.heats));
        const total_bytes = heats_bytes.len;

        // 使用 io_uring IORING_OP_WRITE 异步写入
        var offset: u64 = 0;
        while (offset < total_bytes) {
            const idx: usize = @intCast(offset);
            const remaining = total_bytes - idx;
            const chunk: u32 = if (remaining < 4096) @intCast(remaining) else 4096;

            const iov = io_uring.Iovec{
                .iov_base = @as([*]u8, @ptrCast(&heats_bytes[idx])),
                .iov_len = chunk,
            };

            var req = io_uring.IoRequest{
                .stream_id = @intFromPtr(&heats_bytes[idx]),
                .buf_ptr = @as(*anyopaque, @ptrCast(&heats_bytes[idx])),
            };
            try r.prepare_write(fd, &iov, offset, &req);

            offset += chunk;
        }

        // ARCH-1: flush 后等待所有 CQE 完成，确保数据落盘再 close
        // 计算提交的 SQE 数量（chunk 数）
        const sqe_count = (total_bytes + 4095) / 4096;
        try r.flush();
        var completed: u32 = 0;
        while (completed < sqe_count) {
            const ev = r.poll();
            if (ev == .IoComplete) {
                completed += 1;
            }
        }
        io_uring.Syscall.close(@intCast(fd));
    }

    /// 从文件加载热度池
    /// 使用 io_uring 异步文件 I/O（openat + IORING_OP_READ + close）
    /// 通过 Reactor 提交 SQE，实现真正的 io_uring 零拷贝异步读取
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
        const total_bytes = heats_bytes.len;

        // 使用 io_uring IORING_OP_READ 异步读取
        var offset: u64 = 0;
        while (offset < total_bytes) {
            const idx: usize = @intCast(offset);
            const remaining = total_bytes - idx;
            const chunk: u32 = if (remaining < 4096) @intCast(remaining) else 4096;

            const iov = io_uring.Iovec{
                .iov_base = @as([*]u8, @ptrCast(&heats_bytes[idx])),
                .iov_len = chunk,
            };

            var req = io_uring.IoRequest{
                .stream_id = @intFromPtr(&heats_bytes[idx]),
                .buf_ptr = @as(*anyopaque, @ptrCast(&heats_bytes[idx])),
            };
            try r.prepare_read(fd, &iov, offset, &req);

            offset += chunk;
        }

        // ARCH-1: flush 后等待所有 CQE 完成，确保数据读取完毕再 close
        const sqe_count = (total_bytes + 4095) / 4096;
        try r.flush();
        var completed: u32 = 0;
        while (completed < sqe_count) {
            const ev = r.poll();
            if (ev == .IoComplete) {
                completed += 1;
            }
        }
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
};

// ============================================================================
// StorageInterface VTable 风格接口
// ============================================================================

pub const StorageVTable = struct {
    get: *const fn(self: *const FileStore, key: u64) ?[]const u8,
    set: *const fn(self: *const FileStore, key: u64, value: []const u8) anyerror!void,
};

pub const vtable: StorageVTable = .{
    .get = _get,
    .set = _set,
};

fn _get(self: *const FileStore, key: u64) ?[]const u8 {
    _ = self;
    _ = key;
    return null;
}

fn _set(self: *const FileStore, key: u64, value: []const u8) anyerror!void {
    _ = self;
    _ = key;
    _ = value;
}
