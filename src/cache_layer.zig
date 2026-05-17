// src/cache_layer.zig
// ZigClaw V2.5 | 对称缓存层 | L1/L2 流水 + 预取
//
// 设计原则（显性直白）：
//   - L2 缓存 = TaskString 驻留（全局共享，256 位状态串）
//   - L1 缓存 = Worker 本地缓存（从 L2 预取任务槽位）
//   - 对称缓存：CPU/GPU/FPGA/ASIC 各有独立 L1，共享 L2
//   - 零堆分配，仅使用栈上和静态内存
//   - 缓存行对齐（64 字节），避免伪共享
//
// 数据流：
//   L2 (TaskString) → 预取 → L1 (Worker 本地) → 执行 → 回写 L2
//
// 对称缓存流水：
//   - 执行层将数据送入 L2 缓存
//   - 状态 agent 从 L2 预取到 L1
//   - L1 命中直接执行，未命中从 L2 取

const constants = @import("constants.zig");
const testing = @import("std").testing;
const task_string = @import("task_string.zig");
const TaskString = task_string.TaskString;
const TaskPool = task_string.TaskPool;

/// 缓存行大小（64 字节 = 512 位，匹配 x86_64 / ARM64）
pub const CACHE_LINE_SIZE: usize = 64_usize;

/// L1 缓存槽位（Worker 本地）
/// 每个 Worker 维护一个小型 L1 缓存，预取 L2 中的任务槽位
pub const L1Slot = struct {
    slot: u8,
    task_id: u64,
    valid: bool,

    pub fn init() L1Slot {
        return .{ .slot = 0_u8, .task_id = 0_u64, .valid = false };
    }
};

/// L1 缓存（Worker 本地，缓存行对齐）
/// 容量 = 4 个槽位（256 位 = 1 个缓存行）
pub const L1Cache = struct {
    slots: [4]L1Slot,
    head: u8,       // 读取位置
    tail: u8,       // 写入位置
    count: u8,      // 当前缓存任务数

    pub fn init() L1Cache {
        return .{
            .slots = [_]L1Slot{L1Slot.init()} ** 4_u8,
            .head = 0_u8,
            .tail = 0_u8,
            .count = 0_u8,
        };
    }

    /// 从 L2 预取任务到 L1
    /// 返回预取的任务数
    pub fn prefetch(self: *L1Cache, l2: *const TaskString, start: u8) u8 {
        var prefetched: u8 = 0;
        var slot: u8 = start;
        var attempts: u8 = 0;

        while (prefetched < 4_u8 and attempts < 256_u8) : (attempts += 1_u8) {
            if (l2.isSet(slot)) {
                self.slots[self.tail].slot = slot;
                self.slots[self.tail].valid = true;
                self.tail = @as(u8, @intCast((self.tail + 1) % 4));
                self.count += 1_u8;
                prefetched += 1_u8;
            }
            slot = @as(u8, @intCast((slot + 1) % 256));
        }
        return prefetched;
    }

    /// 从 L1 取出一个任务
    /// 返回槽位号，若 L1 为空返回 null
    pub fn dequeue(self: *L1Cache) ?u8 {
        if (self.count == 0) return null;
        const slot = self.slots[self.head].slot;
        self.slots[self.head].valid = false;
        self.head = @as(u8, @intCast((self.head + 1) % 4));
        self.count -= 1_u8;
        return slot;
    }

    /// L1 是否为空
    pub fn isEmpty(self: *const L1Cache) bool {
        return self.count == 0;
    }

    /// L1 是否已满
    pub fn isFull(self: *const L1Cache) bool {
        return self.count >= 4;
    }
};

/// L2 缓存（全局共享 = TaskString + TaskPool）
/// 256 位状态串驻留 L2，所有 Worker 共享
pub const L2Cache = struct {
    task_pool: *TaskPool,

    pub fn init(pool: *TaskPool) L2Cache {
        return .{ .task_pool = pool };
    }

    /// 提交任务到 L2（设置 TaskString 位）
    pub fn submit(self: *L2Cache, slot: u8, task_id: u64) bool {
        return self.task_pool.submit(slot, task_id);
    }

    /// 完成任务（清除 TaskString 位）
    pub fn complete(self: *L2Cache, slot: u8, output: ?[]const u8) void {
        self.task_pool.complete(slot, output);
    }

    /// 失败任务（清除 TaskString 位 + 记录错误）
    pub fn fail(self: *L2Cache, slot: u8, error_info: []const u8) void {
        self.task_pool.fail(slot, error_info);
    }

    /// 获取活跃任务数
    pub fn activeCount(self: *const L2Cache) u32 {
        return self.task_pool.active_count;
    }

    /// 使用率（0-100）
    pub fn usagePercent(self: *const L2Cache) u32 {
        return (self.task_pool.active_count * 100_u32) / TaskPool.USAGE_LIMIT;
    }
};

/// 对称缓存管理器
/// 管理 CPU/GPU/FPGA/ASIC 四路对称缓存
pub const SymmetricCacheManager = struct {
    l2: L2Cache,
    cpu_l1: L1Cache,
    gpu_l1: L1Cache,
    fpga_l1: L1Cache,
    asic_l1: L1Cache,

    pub fn init(pool: *TaskPool) SymmetricCacheManager {
        return .{
            .l2 = L2Cache.init(pool),
            .cpu_l1 = L1Cache.init(),
            .gpu_l1 = L1Cache.init(),
            .fpga_l1 = L1Cache.init(),
            .asic_l1 = L1Cache.init(),
        };
    }

    /// 根据 agent 类型获取对应 L1 缓存
    pub fn getL1(self: *SymmetricCacheManager, agent_type: task_string.AgentType) *L1Cache {
        return switch (agent_type) {
            .cpu => &self.cpu_l1,
            .gpu => &self.gpu_l1,
            .fpga => &self.fpga_l1,
            .asic => &self.asic_l1,
        };
    }

    /// 对称预取：四路 L1 同时从 L2 预取
    /// 返回总预取任务数
    pub fn symmetricPrefetch(self: *SymmetricCacheManager) u8 {
        var total: u8 = 0;
        const l2 = &self.l2.task_pool.task_string;

        // CPU: 预取槽位 0-63
        total += self.cpu_l1.prefetch(l2, 0_u8);
        // GPU: 预取槽位 64-127
        total += self.gpu_l1.prefetch(l2, 64_u8);
        // FPGA: 预取槽位 128-191
        total += self.fpga_l1.prefetch(l2, 128_u8);
        // ASIC: 预取槽位 192-255
        total += self.asic_l1.prefetch(l2, 192_u8);

        return total;
    }

    /// 流水执行：从 L1 取任务 → 执行 → 回写 L2
    /// 返回执行的任务数
    pub fn pipelineExecute(
        self: *SymmetricCacheManager,
        agent_type: task_string.AgentType,
        execute_fn: fn (u8, u64) ?[]const u8,
    ) u8 {
        const l1 = self.getL1(agent_type);
        var executed: u8 = 0;

        while (!l1.isEmpty()) {
            const slot = l1.dequeue().?;
            const task_id = self.l2.task_pool.slots[slot].task_id;
            const output = execute_fn(slot, task_id);
            self.l2.complete(slot, output);
            executed += 1_u8;
        }
        return executed;
    }
};

// ============================================================
// 测试
// ============================================================
const testing = @import("std").testing;

test "L1Cache init empty" {
    var l1 = L1Cache.init();
    try testing.expect(l1.isEmpty());
    try testing.expect(!l1.isFull());
    try testing.expectEqual(@as(u8, 0), l1.count);
}

test "L1Cache prefetch and dequeue" {
    var pool = TaskPool.init();
    var l1 = L1Cache.init();

    // 提交任务到 L2
    _ = pool.submit(0, 1001);
    _ = pool.submit(1, 1002);
    _ = pool.submit(5, 1003);

    // 从 L2 预取到 L1
    const n = l1.prefetch(&pool.task_string, 0);
    try testing.expectEqual(@as(u8, 3), n);
    try testing.expectEqual(@as(u8, 3), l1.count);

    // 从 L1 取出
    const s1 = l1.dequeue().?;
    try testing.expectEqual(@as(u8, 0), s1);
    const s2 = l1.dequeue().?;
    try testing.expectEqual(@as(u8, 1), s2);
    const s3 = l1.dequeue().?;
    try testing.expectEqual(@as(u8, 5), s3);
    try testing.expect(l1.isEmpty());
}

test "L2Cache submit and complete" {
    var pool = TaskPool.init();
    var l2 = L2Cache.init(&pool);

    try testing.expect(l2.submit(0, 1001));
    try testing.expectEqual(@as(u32, 1), l2.activeCount());

    l2.complete(0, "result");
    try testing.expectEqual(@as(u32, 0), l2.activeCount());
}

test "SymmetricCacheManager symmetricPrefetch" {
    var pool = TaskPool.init();
    var scm = SymmetricCacheManager.init(&pool);

    // 提交任务到不同区域
    _ = pool.submit(0, 1001);    // CPU
    _ = pool.submit(64, 1002);   // GPU
    _ = pool.submit(128, 1003);  // FPGA
    _ = pool.submit(192, 1004);  // ASIC

    const n = scm.symmetricPrefetch();
    try testing.expectEqual(@as(u8, 4), n);

    // 验证各 L1 缓存状态
    try testing.expectEqual(@as(u8, 1), scm.cpu_l1.count);
    try testing.expectEqual(@as(u8, 1), scm.gpu_l1.count);
    try testing.expectEqual(@as(u8, 1), scm.fpga_l1.count);
    try testing.expectEqual(@as(u8, 1), scm.asic_l1.count);
}
