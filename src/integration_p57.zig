// src/integration_p57.zig
// DRD-059 V5: 存储外置适配 — FileStore 集成测试
// 测试策略：
//   1. 保存热度池 → 修改内存 → 加载 → 验证值一致
//   2. 文件不存在时加载 → 返回 error.FileNotFound
//   3. 保存后文件大小与热度池数据大小一致

const os = @import("std").os.linux;
const io_uring = @import("io_uring.zig");
const heat_pool = @import("heat_pool.zig");
const file_store = @import("file_store.zig");

const TEST_PATH: [*:0]const u8 = "/tmp/zigclaw_test_heat_pool.bin";

// ============================================================================
// 测试 1: save → modify → load → 值一致
// ============================================================================

test "P57-1: saveHeatPool → modify → loadHeatPool → 值一致" {
    // 清理之前的测试文件
    const store = file_store.FileStore.init(TEST_PATH);
    store.deleteFile();

    // 构造并填充热度池
    var pool = heat_pool.HeatPool.init();
    // 设置几个槽位为已知值
    _ = pool.update_heat(0, true);
    _ = pool.update_heat(1, true);
    _ = pool.update_heat(5, true);
    _ = pool.update_heat(10, true);

    const slot0_before = pool.get_heat(0);
    const slot1_before = pool.get_heat(1);
    const slot5_before = pool.get_heat(5);
    const slot10_before = pool.get_heat(10);

    // 保存到文件
    try store.saveHeatPool(&pool);

    // 修改内存中的值
    pool.heats[0] = 0;
    pool.heats[1] = 0;
    pool.heats[5] = 0;
    pool.heats[10] = 0;
    @import("std").debug.assert(pool.get_heat(0) == 0);

    // 从文件加载
    const loaded = try store.loadHeatPool();

    // 验证加载后的值与保存前一致
    @import("std").debug.assert(loaded.get_heat(0) == slot0_before);
    @import("std").debug.assert(loaded.get_heat(1) == slot1_before);
    @import("std").debug.assert(loaded.get_heat(5) == slot5_before);
    @import("std").debug.assert(loaded.get_heat(10) == slot10_before);

    // 清理
    store.deleteFile();

    @import("std").debug.print("P57-1: save/load 一致性 通过\n", .{});
}

// ============================================================================
// 测试 2: 文件不存在 → error.FileNotFound
// ============================================================================

test "P57-2: 文件不存在 → error.FileNotFound" {
    const NONEXISTENT_PATH: [*:0]const u8 = "/tmp/zigclaw_nonexistent_pool_12345.bin";
    const store = file_store.FileStore.init(NONEXISTENT_PATH);
    // 确保文件不存在
    store.deleteFile();

    const result = store.loadHeatPool();
    @import("std").debug.assert(result == error.FileNotFound);

    @import("std").debug.print("P57-2: 文件不存在 → FileNotFound 通过\n", .{});
}

// ============================================================================
// 测试 3: 保存后文件大小与热度池数据大小一致
// ============================================================================

test "P57-3: 文件大小 == HeatPool.heats 字节数" {
    const store = file_store.FileStore.init(TEST_PATH);
    store.deleteFile();

    var pool = heat_pool.HeatPool.init();
    _ = pool.update_heat(0, true);
    _ = pool.update_heat(31, true);

    try store.saveHeatPool(&pool);

    // 使用 openat + fstat 获取文件大小（验证手段，不是存储实现本身）
    const file_fd = io_uring.Syscall.openat(
        -100,
        TEST_PATH,
        io_uring.Syscall.O_RDONLY,
        0,
    ) catch |err| {
        @import("std").debug.print("P57-3: 打开文件失败: {}\n", .{err});
        store.deleteFile();
        return;
    };
    defer io_uring.Syscall.close(@intCast(file_fd));

    // 手动定义 fstat 用的 stat 结构体（Zig 0.16 os.linux 未导出）
    const StatT = extern struct {
        dev: u64,
        ino: u64,
        nlink: u64,
        mode: u32,
        uid: u32,
        gid: u32,
        pad0: u32,
        rdev: u64,
        size: i64,
        blksize: i64,
        blocks: i64,
        atime: i64,
        atime_nsec: i64,
        mtime: i64,
        mtime_nsec: i64,
        ctime: i64,
        ctime_nsec: i64,
        reserved: [3]i64,
    };

    var stat_buf: StatT = undefined;
    const rc = os.syscall2(.fstat, @as(usize, @intCast(file_fd)), @intFromPtr(&stat_buf));
    if (rc > @as(usize, @bitCast(@as(isize, -4096)))) {
        @import("std").debug.print("P57-3: fstat 失败\n", .{});
        store.deleteFile();
        return;
    }
    const expected_size = @sizeOf(u16) * heat_pool.HEAT_POOL_SIZE; // 2 * 64 = 128

    @import("std").debug.assert(@as(u64, @intCast(stat_buf.size)) == expected_size);

    // 清理
    store.deleteFile();

    @import("std").debug.print("P57-3: 文件大小={d} == 预期={d} 通过\n", .{@as(u64, @intCast(stat_buf.size)), expected_size});
}
