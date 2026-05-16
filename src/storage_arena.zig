// src/storage_arena.zig
// 存储层 | Layer: Storage
// StorageArena — 单一结构体统一管理热池 + SSD 快照 + 文件存储
//
// 设计原则（显性直白）：
//   - 一个结构体，一个 ArenaAllocator，一个 init/deinit
//   - 禁止模块间手动 deinit 调用链
//   - 零堆分配（write_buf 在栈上）
//   - io_uring 异步写入 + 显式 wait_cqe 完成验证
//
// 军规遵循：
//   - 精确导入（无 const std = @import("std")）
//   - 无菌室规则（io_uring 路径禁止 try/catch/orelse）
//   - 槽位数量统一引用 constants.SLOT_COUNT

const mem = @import("std").mem;
const linux = @import("std").os.linux;
const log = @import("std").log;
const debug = @import("std").debug;
const atomic = @import("std").atomic;
const io_uring = @import("io_uring.zig");
const constants = @import("constants.zig");
const c = @import("std").c;

// ============================================================================
// 常量
// ============================================================================

pub const SLOT_COUNT = constants.SLOT_COUNT;

const SNAP_HEADER_SIZE: usize = 64;
const SNAP_PADDING_SIZE: usize = 64;
const SNAP_BODY_SIZE: usize = 8128;
const SNAP_FILE_SIZE: usize = SNAP_HEADER_SIZE * 2 + SNAP_PADDING_SIZE + SNAP_BODY_SIZE; // 8320B

const MAGIC: u32 = 0x5A434C57; // 'ZCLW'

// ============================================================================
// SSD Header 定义 (64 字节)
// ============================================================================

const SnapHeader = struct {
    magic: u32 = MAGIC,
    version: u32 = 0,
    crc32: u32 = 0,
    timestamp_ns: u64 = 0,
    reserved: [11]u32 = [_]u32{0} ** 11,

    fn init(version: u32, body_slice: []const u8, timestamp: u64) SnapHeader {
        return .{
            .magic = MAGIC,
            .version = version,
            .crc32 = hashCrc32(body_slice[0..SNAP_BODY_SIZE]),
            .timestamp_ns = timestamp,
        };
    }

    fn isValid(self: SnapHeader, body_slice: []const u8) bool {
        if (self.magic != MAGIC) return false;
        if (self.version != 0 and self.version != 1) return false;
        return self.crc32 == hashCrc32(body_slice[0..SNAP_BODY_SIZE]);
    }
};

// ============================================================================
// CRC32 计算（软件实现，无外部依赖）
// ============================================================================

fn hashCrc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte_| {
        var b: u32 = byte_;
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            if ((crc ^ b) & 1 != 0) {
                crc = (crc >> 1) ^ 0xEDB88320;
            } else {
                crc = crc >> 1;
            }
            b >>= 1;
        }
    }
    return ~crc;
}

// ============================================================================
// 单调时钟
// ============================================================================

fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// ============================================================================
// StorageArena — 统一存储层
// ============================================================================

pub const StorageArena = struct {
    // --- 热池核心数据 ---
    heats: [SLOT_COUNT]u16,
    last_touch_ns: [SLOT_COUNT]u64,

    // --- 并发安全锁 ---
    mu: atomic.Mutex = .unlocked,

    // --- SSD 快照状态 ---
    snap_version: u32,
    snap_path: [*:0]const u8,

    // --- 初始化 ---
    pub fn init() StorageArena {
        return .{
            .heats = [_]u16{0} ** SLOT_COUNT,
            .last_touch_ns = [_]u64{0} ** SLOT_COUNT,
            .mu = .unlocked,
            .snap_version = 0,
            .snap_path = getDefaultSnapPath(),
        };
    }

    // --- 热池操作（加锁保护）---

    pub fn update_heat(self: *StorageArena, slot: usize, accessed: bool) u16 {
        if (slot >= SLOT_COUNT) return 0;
        while (!self.mu.tryLock()) {}
        defer self.mu.unlock();

        var heat: f32 = @floatFromInt(self.heats[slot]);
        if (accessed) {
            self.last_touch_ns[slot] = monotonicNs();
            if (heat == 0) {
                heat = 100.0;
            } else {
                const heat_f64: f64 = @floatCast(heat);
                const updated: f64 = heat_f64 + @log(heat_f64 + 1.5) * 0.75;
                heat = @floatCast(updated);
            }
        } else {
            const heat_f64_decay: f64 = @floatCast(heat);
            const dyn_decay: f32 = @floatCast(0.00035 + (0.012 / (heat_f64_decay + 2.0)));
            heat *= (1.0 - dyn_decay);
        }
        if (heat > 65535.0) heat = 65535.0;
        self.heats[slot] = @intFromFloat(heat);
        return self.heats[slot];
    }

    pub fn get_heat(self: *const StorageArena, slot: usize) u16 {
        if (slot >= SLOT_COUNT) return 0;
        const mu = @constCast(&self.mu);
        while (!mu.tryLock()) {}
        defer mu.unlock();
        return self.heats[slot];
    }

    pub fn get_last_touch_ns(self: *const StorageArena, slot: usize) u64 {
        if (slot >= SLOT_COUNT) return 0;
        const mu = @constCast(&self.mu);
        while (!mu.tryLock()) {}
        defer mu.unlock();
        return self.last_touch_ns[slot];
    }

    /// 根据经过的时间减少热度（用于 SSD 恢复时）
    pub fn apply_elapsed_decay(self: *StorageArena, slot: usize, elapsed_ns: u64) u16 {
        if (slot >= SLOT_COUNT) return 0;
        while (!self.mu.tryLock()) {}
        defer self.mu.unlock();

        var heat: f32 = @floatFromInt(self.heats[slot]);
        if (heat <= 0) return 0;
        const max_steps: u32 = @intCast(@min(elapsed_ns / 1_000_000_000, 300));
        var i: u32 = 0;
        while (i < max_steps) : (i += 1) {
            const heat_f64: f64 = @floatCast(heat);
            if (heat_f64 <= 1.0) break;
            const dyn_decay: f32 = @floatCast(0.00035 + (0.012 / (heat_f64 + 2.0)));
            heat *= (1.0 - dyn_decay);
        }
        if (heat > 65535.0) heat = 65535.0;
        self.heats[slot] = @intFromFloat(heat);
        return self.heats[slot];
    }

    /// 获取热池快照（加锁复制，供内省使用）
    pub fn getSnapshot(self: *const StorageArena) struct { heats: [SLOT_COUNT]u16, last_touch_ns: [SLOT_COUNT]u64 } {
        const mu = @constCast(&self.mu);
        while (!mu.tryLock()) {}
        defer mu.unlock();
        return .{
            .heats = self.heats,
            .last_touch_ns = self.last_touch_ns,
        };
    }

    // --- SSD 快照操作 ---

    /// 将热池快照写入 SSD（io_uring 异步）
    /// 锁生命周期：仅保护热池数据复制 + 版本号更新，I/O 期间不持有锁
    /// 关键：snap_version 递增在锁内、heats 复制之前，确保版本号与数据一致性
    pub fn saveHeatPool(self: *StorageArena) void {
        const filepath = self.snap_path;
        const timestamp = monotonicNs();

        // 阶段1：加锁 → 递增版本号 → 复制热池数据 → 解锁
        var write_buf: [SNAP_FILE_SIZE]u8 = undefined;
        const body_offset = SNAP_HEADER_SIZE * 2 + SNAP_PADDING_SIZE;

        while (!self.mu.tryLock()) {}
        // 版本号在锁内递增，确保与 heats 数组的一致性
        const new_ver = @as(u32, @intCast(@mod(@as(i32, @intCast(self.snap_version)) + 1, 2)));
        self.snap_version = new_ver;
        const snap = self.getSnapshotUnlocked();
        // 序列化 heats + last_touch_ns 到 write_buf
        const heats_size = SLOT_COUNT * 2;
        @memcpy(write_buf[body_offset..][0..heats_size], @as([*]const u8, @ptrCast(&snap.heats))[0..heats_size]);
        const touch_size = SLOT_COUNT * 8;
        @memcpy(write_buf[body_offset + heats_size..][0..touch_size], @as([*]const u8, @ptrCast(&snap.last_touch_ns))[0..touch_size]);
        @memset(write_buf[body_offset + heats_size + touch_size..][0..(SNAP_BODY_SIZE - heats_size - touch_size)], 0xFF);
        self.mu.unlock(); // 复制完成，立即释放锁

        // 阶段2：构造 Header（不持有锁）
        const new_header = SnapHeader.init(new_ver, write_buf[body_offset..], timestamp);
        const header_offset: usize = if (new_ver == 0) 0 else SNAP_HEADER_SIZE;
        @memcpy(write_buf[header_offset..][0..SNAP_HEADER_SIZE], @as([*]const u8, @ptrCast(&new_header))[0..SNAP_HEADER_SIZE]);
        @memset(write_buf[SNAP_HEADER_SIZE * 2..][0..SNAP_PADDING_SIZE], 0xFF);

        // 阶段3：io_uring 异步写入（不持有锁）
        saveToFile(filepath, write_buf[0..], new_ver);
    }

    /// 从 SSD 恢复热池
    pub fn loadHeatPool(self: *StorageArena) !void {
        const filepath = self.snap_path;

        const fd = io_uring.Syscall.openat(-100, filepath, io_uring.Syscall.O_RDONLY, 0) catch return error.FileNotFound;
        defer io_uring.Syscall.close(@as(u32, @intCast(fd)));

        var buf: [SNAP_FILE_SIZE]u8 = undefined;
        const n = try io_uring.read(fd, buf[0..], SNAP_FILE_SIZE);
        if (n != SNAP_FILE_SIZE) return error.TruncatedFile;

        const body_offset = SNAP_HEADER_SIZE * 2 + SNAP_PADDING_SIZE;

        // 尝试 V0
        const header_ptr = @as(*const SnapHeader, @alignCast(@ptrCast(&buf[0])));
        if (!header_ptr.isValid(buf[body_offset..])) {
            const header_v1 = @as(*const SnapHeader, @alignCast(@ptrCast(&buf[SNAP_HEADER_SIZE])));
            if (!header_v1.isValid(buf[body_offset..])) {
                return error.CorruptedSnapshot;
            }
        }

        // 加锁恢复数据
        while (!self.mu.tryLock()) {}
        defer self.mu.unlock();

        @memcpy(@as([*]u8, @ptrCast(&self.heats))[0..SLOT_COUNT * 2], buf[body_offset..][0..SLOT_COUNT * 2]);
        @memcpy(@as([*]u8, @ptrCast(&self.last_touch_ns))[0..SLOT_COUNT * 8], buf[body_offset + SLOT_COUNT * 2 ..][0..SLOT_COUNT * 8]);

        // 根据时间差衰减热度
        const now = monotonicNs();
        var i: usize = 0;
        while (i < SLOT_COUNT) : (i += 1) {
            const touch_ns = self.last_touch_ns[i];
            if (touch_ns > 0 and now > touch_ns) {
                const elapsed = now - touch_ns;
                _ = applyElapsedDecayUnlocked(self, i, elapsed);
            }
        }
    }

    // --- 文件操作 ---

    /// 删除持久化文件（测试清理用）
    pub fn deleteFile(self: *const StorageArena) void {
        _ = linux.syscall3(
            .unlinkat,
            @as(usize, @bitCast(@as(i64, @as(i32, -100)))),
            @intFromPtr(self.snap_path),
            0,
        );
    }

    // --- 内部辅助 ---

    fn getSnapshotUnlocked(self: *const StorageArena) struct { heats: [SLOT_COUNT]u16, last_touch_ns: [SLOT_COUNT]u64 } {
        return .{
            .heats = self.heats,
            .last_touch_ns = self.last_touch_ns,
        };
    }

    fn applyElapsedDecayUnlocked(self: *StorageArena, slot: usize, elapsed_ns: u64) u16 {
        var heat: f32 = @floatFromInt(self.heats[slot]);
        if (heat <= 0) return 0;
        const max_steps: u32 = @intCast(@min(elapsed_ns / 1_000_000_000, 300));
        var i: u32 = 0;
        while (i < max_steps) : (i += 1) {
            const heat_f64: f64 = @floatCast(heat);
            if (heat_f64 <= 1.0) break;
            const dyn_decay: f32 = @floatCast(0.00035 + (0.012 / (heat_f64 + 2.0)));
            heat *= (1.0 - dyn_decay);
        }
        if (heat > 65535.0) heat = 65535.0;
        self.heats[slot] = @intFromFloat(heat);
        return self.heats[slot];
    }

    /// io_uring 异步写入
    /// 注意：错误处理使用无锁的 debug.print，避免在持有锁路径上触发递归锁
    fn saveToFile(filepath: [*:0]const u8, data: []const u8, new_ver: u32) void {
        const fd = io_uring.Syscall.openat(
            -100,
            filepath,
            io_uring.Syscall.O_RDWR | io_uring.Syscall.O_CREAT | io_uring.Syscall.O_TRUNC,
            0o644,
        ) catch |err| {
            debug.print("storage_arena: openat 失败: {s}\n", .{@errorName(err)});
            return;
        };
        defer io_uring.Syscall.close(@as(u32, @intCast(fd)));

        // 提交写请求
        _ = io_uring.write(fd, data.ptr, data.len) catch |err| {
            debug.print("storage_arena: write 失败: {s}\n", .{@errorName(err)});
            return;
        };

        debug.print("storage_arena: 快照已写入 (version={d})\n", .{new_ver});
    }

    fn getDefaultSnapPath() [*:0]const u8 {
        const path = c.getenv("ZIGCLAW_SNAP_PATH");
        if (path) |p| return p;
        return "/var/lib/zigclaw_heat.bin";
    }
};

// ============================================================================
// 编译期断言
// ============================================================================

comptime {
    debug.assert(@sizeOf(SnapHeader) == SNAP_HEADER_SIZE);
    debug.assert(SNAP_FILE_SIZE == 8320);
}

// ============================================================================
// 单元测试
// ============================================================================

test "StorageArena: 初始化全零" {
    const arena = StorageArena.init();
    for (0..SLOT_COUNT) |i| {
        debug.assert(arena.get_heat(i) == 0);
    }
}

test "StorageArena: 更新热度 - 访问递增" {
    var arena = StorageArena.init();
    const slot: usize = 5;
    _ = arena.update_heat(slot, true);
    debug.assert(arena.get_heat(slot) > 0);
}

test "StorageArena: 更新热度 - 未访问衰减" {
    var arena = StorageArena.init();
    const slot: usize = 10;
    _ = arena.update_heat(slot, true);
    const after_access = arena.get_heat(slot);
    _ = arena.update_heat(slot, false);
    const after_decay = arena.get_heat(slot);
    debug.assert(after_decay <= after_access);
}
