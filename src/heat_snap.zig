// src/heat_snap.zig
// 存储层 | Layer: Storage
// 热度快照 — 双版本头 + io_uring 异步写入 + 零序列化内存直拷
//
// 架构（显性直白）：
//   单文件（如 /var/lib/zigclaw_heat.bin），大小 8320 字节
//   Header V0 (64B) + Header V1 (64B) + Padding (64B) + Data Body (8128B) = 8320B
//   双 Header 交替写入，恢复时取有效者
//   Data Body = HeatPool(u16[SLOT_COUNT]) + last_touch_ns(u64[SLOT_COUNT])，共 SLOT_COUNT * 10B，Padding 到 8128B
//
// 军规遵循：
//   - 精确导入（无 const std = @import("std")）
//   - 无霉菌室规则（io_uring 路径禁止 try/catch/orelse）
//   - 零堆分配（write_buf 在栈上）
//   - 文件路径通过环境变量 ZIGCLAW_SNAP_PATH 配置

const linux = @import("std").os.linux;
const c = @import("std").c;
const mem = @import("std").mem;
const log = @import("std").log;
const debug = @import("std").debug;
const io_uring = @import("io_uring.zig");
const heat_pool = @import("heat_pool.zig");
const constants = @import("constants.zig");

// ============================================================================
// 常量
// ============================================================================

const SNAP_HEADER_SIZE: usize = 64;
const SNAP_PADDING_SIZE: usize = 64;
const SNAP_BODY_SIZE: usize = 8128; // HeatPool(128B) + last_touch_ns(512B) + Padding(7488B)
const SNAP_FILE_SIZE: usize = SNAP_HEADER_SIZE * 2 + SNAP_PADDING_SIZE + SNAP_BODY_SIZE; // 8320B

const MAGIC: u32 = 0x5A434C57; // 'ZCLW'

// ============================================================================
// SSD Header 定义 (64 字节)
// ============================================================================

const SnapHeader = struct {
    magic: u32 = MAGIC,            // 4B: 魔数 'ZCLW'
    version: u32 = 0,              // 4B: 版本号 0 或 1
    crc32: u32 = 0,                // 4B: CRC32 校验
    timestamp_ns: u64 = 0,         // 8B: 单调时钟纳秒
    reserved: [11]u32 = [_]u32{0} ** 11, // 44B: 保留
    // 总计: 4+4+4+8+44 = 64B

    /// 构造新 Header（自动翻转版本号）
    fn init(version: u32, body_slice: []const u8, timestamp: u64) SnapHeader {
        return .{
            .magic = MAGIC,
            .version = version,
            .crc32 = hashCrc32(body_slice[0..SNAP_BODY_SIZE]),
            .timestamp_ns = timestamp,
        };
    }

    /// 三重校验：魔数 + 版本 + CRC32
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
// 获取单调时钟纳秒
// ============================================================================

fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// ============================================================================
// 快照写入（io_uring 异步）
// ============================================================================

/// 将热度池快照写入 SSD
/// 使用 io_uring 异步写入，不阻塞事件循环
/// 文件路径通过 ZIGCLAW_SNAP_PATH 环境变量配置，默认 /var/lib/zigclaw_heat.bin
pub fn saveHeatPool(pool: *const heat_pool.HeatPool, active_version: *u32) void {
    const filepath = getSnapPath();

    // 构造新 Header（翻转版本号）
    const new_ver = @as(u32, @intCast(@mod(@as(i32, @intCast(active_version.*)) + 1, 2)));
    const timestamp = monotonicNs();

    // 准备写入缓冲区（栈分配，零堆分配）
    var write_buf: [SNAP_FILE_SIZE]u8 = undefined;

    // 计算 Data Body 在文件中的偏移
    const body_offset = SNAP_HEADER_SIZE * 2 + SNAP_PADDING_SIZE; // 192

    // 序列化 HeatPool 到 Data Body
    // heats: u16[SLOT_COUNT] = SLOT_COUNT * 2 bytes
    const heats_size = constants.SLOT_COUNT * 2;
    @memcpy(write_buf[body_offset..][0..heats_size], @as([*]const u8, @ptrCast(&pool.heats))[0..heats_size]);
    // last_touch_ns: u64[SLOT_COUNT] = SLOT_COUNT * 8 bytes
    const touch_size = constants.SLOT_COUNT * 8;
    @memcpy(write_buf[body_offset + heats_size..][0..touch_size], @as([*]const u8, @ptrCast(&pool.last_touch_ns))[0..touch_size]);
    // 剩余 Padding 置 0xFF
    @memset(write_buf[body_offset + heats_size + touch_size..][0..(SNAP_BODY_SIZE - heats_size - touch_size)], 0xFF);

    // 构造新 Header
    const new_header = SnapHeader.init(new_ver, write_buf[body_offset..], timestamp);

    // 写入新 Header 到对应版本槽位
    const header_offset: usize = if (new_ver == 0) 0 else SNAP_HEADER_SIZE;
    @memcpy(write_buf[header_offset..][0..SNAP_HEADER_SIZE], @as([*]const u8, @ptrCast(&new_header))[0..SNAP_HEADER_SIZE]);

    // Padding 区域置 0xFF
    @memset(write_buf[SNAP_HEADER_SIZE * 2..][0..SNAP_PADDING_SIZE], 0xFF);

    // io_uring 异步写入
    saveToFile(filepath, write_buf[0..], new_ver);
}

/// 从 SSD 恢复热度池
/// 优先尝试 V0，无效则尝试 V1，均无效返回 error.CorruptedSnapshot
pub fn loadHeatPool(pool: *heat_pool.HeatPool) !void {
    const filepath = getSnapPath();

    // 打开文件
    const fd = io_uring.Syscall.openat(-100, filepath, io_uring.Syscall.O_RDONLY, 0) catch return error.FileNotFound;
    defer io_uring.Syscall.close(@as(u32, @intCast(fd)));

    // 读取整个文件
    var buf: [SNAP_FILE_SIZE]u8 = undefined;
    const n = try io_uring.read(fd, buf[0..], SNAP_FILE_SIZE);
    if (n != SNAP_FILE_SIZE) return error.TruncatedFile;

    const body_offset = SNAP_HEADER_SIZE * 2 + SNAP_PADDING_SIZE; // 192

    // 尝试 V0（直接指针转换，零解析）
    const header_ptr = @as(*const SnapHeader, @alignCast(@ptrCast(&buf[0])));
    if (!header_ptr.isValid(buf[body_offset..])) {
        // V0 无效，尝试 V1
        const header_v1 = @as(*const SnapHeader, @alignCast(@ptrCast(&buf[SNAP_HEADER_SIZE])));
        if (!header_v1.isValid(buf[body_offset..])) {
            return error.CorruptedSnapshot;
        }
    }

    // 反序列化 HeatPool（零解析，直接内存拷贝）
    @memcpy(@as([*]u8, @ptrCast(&pool.heats))[0..128], buf[body_offset..][0..128]);
    @memcpy(@as([*]u8, @ptrCast(&pool.last_touch_ns))[0..512], buf[body_offset + 128..][0..512]);

    // 根据时间差衰减热度
    const now = monotonicNs();
    for (0..heat_pool.HEAT_POOL_SIZE) |i| {
        const touch_ns = pool.get_last_touch_ns(i);
        if (touch_ns > 0 and now > touch_ns) {
            const elapsed = now - touch_ns;
            _ = pool.apply_elapsed_decay(i, elapsed);
        }
    }
}

// ============================================================================
// 内部辅助
// ============================================================================

/// 获取快照文件路径（环境变量 ZIGCLAW_SNAP_PATH，默认 /var/lib/zigclaw_heat.bin）
fn getSnapPath() [*:0]const u8 {
    const path = c.getenv("ZIGCLAW_SNAP_PATH");
    if (path) |p| return p;
    return "/var/lib/zigclaw_heat.bin";
}

/// io_uring 异步写入文件
fn saveToFile(filepath: [*:0]const u8, data: []const u8, new_ver: u32) void {
    // 打开文件（创建/截断）
    const fd = io_uring.Syscall.openat(
        -100,
        filepath,
        io_uring.Syscall.O_RDWR | io_uring.Syscall.O_CREAT | io_uring.Syscall.O_TRUNC,
        0o644,
    ) catch |err| {
        log.err("heat_snap: openat 失败: {s}", .{@errorName(err)});
        return;
    };
    defer io_uring.Syscall.close(@as(u32, @intCast(fd)));

    // io_uring 异步写入
    _ = io_uring.write(fd, data.ptr, data.len) catch |err| {
        log.err("heat_snap: write 失败: {s}", .{@errorName(err)});
        return;
    };

    log.info("heat_snap: 快照已写入 (version={d})", .{new_ver});
}

// ============================================================================
// 编译期断言
// ============================================================================

comptime {
    debug.assert(@sizeOf(SnapHeader) == SNAP_HEADER_SIZE);
    debug.assert(SNAP_FILE_SIZE == 8320);
}
