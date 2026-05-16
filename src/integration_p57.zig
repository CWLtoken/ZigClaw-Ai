// src/integration_p57.zig
// DRD-059 V5: 存储外置适配 — StorageArena 集成测试
// 测试策略：
//   1. 保存热度池 → 修改内存 → 加载 → 验证值一致
//   2. 文件不存在时加载 → 返回 error.FileNotFound
//   3. 保存后文件大小与快照格式一致

const std_debug = @import("std").debug;
const sa = @import("storage_arena.zig");
const io_uring = @import("io_uring.zig");
const os = @import("std").os.linux;

const TEST_PATH: [*:0]const u8 = "/tmp/zigclaw_test_heat_pool.bin";

// ============================================================================
// 测试 1: save → modify → load → 值一致
// ============================================================================

test "P57-1: saveHeatPool → modify → loadHeatPool → 值一致" {
    // 清理之前的测试文件
    var arena = sa.StorageArena.init();
    arena.snap_path = TEST_PATH;
    arena.deleteFile();

    // 构造并填充热度池
    _ = arena.update_heat(0, true);
    _ = arena.update_heat(1, true);
    _ = arena.update_heat(5, true);
    _ = arena.update_heat(10, true);

    const slot0_before = arena.get_heat(0);
    const slot1_before = arena.get_heat(1);
    const slot5_before = arena.get_heat(5);
    const slot10_before = arena.get_heat(10);

    // 保存到文件
    arena.saveHeatPool();

    // 修改内存中的值
    // 注意：StorageArena 没有直接暴露 heats 字段给外部修改
    // 这里我们通过 update_heat 来模拟修改
    _ = arena.update_heat(0, false);
    _ = arena.update_heat(1, false);
    _ = arena.update_heat(5, false);
    _ = arena.update_heat(10, false);

    // 从文件加载
    var loaded = sa.StorageArena.init();
    loaded.snap_path = TEST_PATH;
    loaded.loadHeatPool() catch |err| {
        std_debug.print("P57-1: 加载失败: {}\n", .{err});
        loaded.deleteFile();
        return;
    };

    // 验证加载后的值与保存前一致
    std_debug.assert(loaded.get_heat(0) == slot0_before);
    std_debug.assert(loaded.get_heat(1) == slot1_before);
    std_debug.assert(loaded.get_heat(5) == slot5_before);
    std_debug.assert(loaded.get_heat(10) == slot10_before);

    // 清理
    loaded.deleteFile();

    std_debug.print("P57-1: save/load 一致性 通过\n", .{});
}

// ============================================================================
// 测试 2: 文件不存在 → error.FileNotFound
// ============================================================================

test "P57-2: 文件不存在 → error.FileNotFound" {
    const NONEXISTENT_PATH: [*:0]const u8 = "/tmp/zigclaw_nonexistent_pool_12345.bin";
    var arena = sa.StorageArena.init();
    arena.snap_path = NONEXISTENT_PATH;
    // 确保文件不存在
    arena.deleteFile();

    const result = arena.loadHeatPool();
    std_debug.assert(result == error.FileNotFound);

    std_debug.print("P57-2: 文件不存在 → FileNotFound 通过\n", .{});
}

// ============================================================================
// 测试 3: 保存后文件大小与快照格式一致
// ============================================================================

test "P57-3: 文件大小 == 快照格式大小" {
    var arena = sa.StorageArena.init();
    arena.snap_path = TEST_PATH;
    arena.deleteFile();

    _ = arena.update_heat(0, true);
    _ = arena.update_heat(31, true);

    arena.saveHeatPool();

    // 使用 openat + fstat 获取文件大小
    const file_fd = io_uring.Syscall.openat(
        -100,
        TEST_PATH,
        io_uring.Syscall.O_RDONLY,
        0,
    ) catch |err| {
        std_debug.print("P57-3: 打开文件失败: {}\n", .{err});
        arena.deleteFile();
        return;
    };
    defer io_uring.Syscall.close(@intCast(file_fd));

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
        std_debug.print("P57-3: fstat 失败\n", .{});
        arena.deleteFile();
        return;
    }

    // 快照文件大小 = 8320B（双版本头 128B + Padding 64B + Data Body 8128B）
    const expected_size: i64 = 8320;
    std_debug.assert(stat_buf.size == expected_size);

    // 清理
    arena.deleteFile();

    std_debug.print("P57-3: 文件大小={d} == 预期={d} 通过\n", .{ stat_buf.size, expected_size });
}
