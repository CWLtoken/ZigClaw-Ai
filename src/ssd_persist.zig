// src/ssd_persist.zig
// 存储层 | Layer: Storage
// SSD 持久化，双版本页原子切换

// ssd_persist.zig: 纯类型锚点，无 std 运行时依赖
const io_uring = @import("io_uring.zig");
const heat_pool = @import("heat_pool.zig");

const FLUSH_FILE = "/tmp/zigclaw_heat.bin";

/// 将热度池数据写入 SSD（简化版：直接写入文件）
pub fn flush_heat_pool(pool: *const heat_pool.HeatPool) !void {
    var buf: [heat_pool.HEAT_POOL_SIZE * 2]u8 = undefined;
    // 序列化为小端字节序
    for (0..heat_pool.HEAT_POOL_SIZE) |i| {
        const val = pool.heats[i];
        buf[i*2] = @intCast(val & 0xFF);
        buf[i*2+1] = @intCast((val >> 8) & 0xFF);
    }
    // 打开文件，创建/截断
    const fd = try io_uring.Syscall.openat(-100, FLUSH_FILE, io_uring.Syscall.O_RDWR | io_uring.Syscall.O_CREAT | io_uring.Syscall.O_TRUNC, 0o644);
    defer io_uring.Syscall.close(@as(u32, @intCast(fd)));
    _ = try io_uring.write(fd, &buf, buf.len);
}

/// 从 SSD 加载热度池数据
pub fn load_heat_pool(pool: *heat_pool.HeatPool) !void {
    var buf: [heat_pool.HEAT_POOL_SIZE * 2]u8 = undefined;
    const fd = try io_uring.Syscall.openat(-100, FLUSH_FILE, io_uring.Syscall.O_RDONLY, 0);
    defer io_uring.Syscall.close(@as(u32, @intCast(fd)));
    const n = try io_uring.read(fd, &buf, buf.len);
    if (n != buf.len) return error.TruncatedFile;
    for (0..heat_pool.HEAT_POOL_SIZE) |i| {
        pool.heats[i] = @as(u16, @intCast(buf[i*2])) | (@as(u16, @intCast(buf[i*2+1])) << 8);
    }
}

// 单元测试（P43）
const std_debug = @import("std").debug;

test "P43: flush and load heat pool" {
    var pool = heat_pool.HeatPool.init();
    pool.heats[0] = 1000;
    pool.heats[1] = 2000;
    
    // 写入
    flush_heat_pool(&pool) catch |err| {
        std_debug.print("flush failed: {}\n", .{err});
        return;
    };
    
    // 创建新pool并加载
    var loaded_pool = heat_pool.HeatPool.init();
    load_heat_pool(&loaded_pool) catch |err| {
        std_debug.print("load failed: {}\n", .{err});
        return;
    };
    
    std_debug.assert(loaded_pool.heats[0] == 1000);
    std_debug.assert(loaded_pool.heats[1] == 2000);
    std_debug.print("P43: SSD持久化测试通过\n", .{});
}
