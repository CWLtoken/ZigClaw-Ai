// src/file_store.zig
// 存储层 | Layer: Storage
// DRD-059 V5: 存储外置适配 — 文件版 FileStore
//
// 设计原则：
//   - 使用 io_uring.Syscall 的文件 I/O 方法（openat/write/read/close）
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
    /// 使用 io_uring.Syscall 的文件 I/O（openat + write + close）
    pub fn saveHeatPool(self: *const FileStore, pool: *const heat_pool.HeatPool) !void {
        // 打开文件（创建 + 截断 + 读写）
        const fd = try io_uring.Syscall.openat(
            -100,
            self.path,
            io_uring.Syscall.O_CREAT | io_uring.Syscall.O_RDWR | io_uring.Syscall.O_TRUNC,
            0o644,
        );
        defer io_uring.Syscall.close(@intCast(fd));

        // 将 heats 数组序列化为字节缓冲区（栈上）
        const heats_bytes = mem.asBytes(&pool.heats);
        const total_bytes = heats_bytes.len;

        // 分块写入（每次最多 4096 字节，适配栈缓冲区）
        var offset: usize = 0;
        while (offset < total_bytes) {
            const chunk = @min(4096, total_bytes - offset);
            const written = io_uring.write(
                fd,
                @as([*]const u8, @ptrCast(&heats_bytes[offset])),
                chunk,
            ) catch return error.WriteFailed;
            offset += written;
        }
    }

    /// 从文件加载热度池
    /// 使用 io_uring.Syscall 的文件 I/O（openat + read + close）
    pub fn loadHeatPool(self: *const FileStore) !heat_pool.HeatPool {
        // 打开文件（只读）
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
        defer io_uring.Syscall.close(@intCast(fd));

        var pool = heat_pool.HeatPool.init();
        const heats_bytes = mem.asBytes(&pool.heats);
        const total_bytes = heats_bytes.len;

        // 分块读取
        var offset: usize = 0;
        while (offset < total_bytes) {
            const chunk = @min(4096, total_bytes - offset);
            const nread = io_uring.read(
                fd,
                @as([*]u8, @ptrCast(&heats_bytes[offset])),
                chunk,
            ) catch return error.ReadFailed;
            if (nread == 0) break; // EOF
            offset += nread;
        }

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
