// src/task_string.zig
// ZigClaw V2.5 | 256 位状态任务串 | 分形树离散化表示
//
// 设计原则（显性直白）：
//   - 256 位 = 4×u64，每位代表一个任务槽
//   - bit=1：该槽有活跃任务；bit=0：该槽空闲或已完成
//   - 原子操作保证多 agent 并发安全，无锁
//   - 零堆分配，仅使用栈上和静态内存
//
// 分形思想：
//   - 数学上：分形树/雪花/海岸线 → 无限细分到状态
//   - 计算上：256 位状态码 → 每位代表一个任务槽 → 无限细分任务
//   - 关键：状态是离散的，任务是连续的，256 位状态码是连续任务离散化的手段
//
// 槽位范围 → 异构类型（隐含）：
//   - 0-63:   CPU  agent（最低难度任务）
//   - 64-127: GPU  agent
//   - 128-191: FPGA agent
//   - 192-255: ASIC agent（最高难度任务）

const constants = @import("constants.zig");

/// 256 位状态任务串（分形树离散化表示）
/// 全局共享，原子操作，紧凑高效
pub const TaskString = struct {
    // 256 位 = 4×u64
    // bits[0] = 槽位 0-63, bits[1] = 槽位 64-127, ...
    bits: [4]u64,

    /// 初始化（全零 = 无活跃任务）
    pub fn init() TaskString {
        return .{ .bits = [_]u64{0} ** 4 };
    }

    /// 设置位（标记为活跃）- 原子操作
    pub fn set(self: *TaskString, slot: u8) void {
        const idx = @as(u32, slot) >> 6;    // /64
        const bit = @as(u6, @intCast(slot & 0x3F));  // %64
        _ = @atomicRmw(u64, &self.bits[idx], .Or, @as(u64, 1) << bit, .monotonic);
    }

    /// 清除位（成功/失败均清除）- 原子操作
    pub fn clear(self: *TaskString, slot: u8) void {
        const idx = @as(u32, slot) >> 6;
        const bit = @as(u6, @intCast(slot & 0x3F));
        _ = @atomicRmw(u64, &self.bits[idx], .And, ~(@as(u64, 1) << bit), .monotonic);
    }

    /// 检查位（非原子，用于单线程扫描）
    pub fn isSet(self: TaskString, slot: u8) bool {
        const idx = @as(u32, slot) >> 6;
        const bit = @as(u6, @intCast(slot & 0x3F));
        return (self.bits[idx] & (@as(u64, 1) << bit)) != 0;
    }

    /// 统计活跃任务数（popcount）
    pub fn popcount(self: TaskString) u32 {
        var n: u32 = 0;
        for (self.bits) |w| {
            n += @popCount(w);
        }
        return n;
    }

    /// 查找第一个活跃槽位（乱序扫描起点）
    /// 返回槽位编号，若无活跃任务返回 null
    pub fn findFirst(self: TaskString) ?u8 {
        for (0..256) |i| {
            if (self.isSet(@intCast(i))) return @intCast(i);
        }
        return null;
    }

    /// 从指定位置查找下一个活跃槽位（乱序扫描）
    /// start: 起始槽位（不包含），返回下一个活跃槽位
    pub fn findNext(self: TaskString, start: u8) ?u8 {
        for ((start + 1)..256) |i| {
            if (self.isSet(@intCast(i))) return @intCast(i);
        }
        return null;
    }

    /// 扫描所有活跃槽位（回调式，无分配）
    pub fn scan(self: TaskString, comptime T: type, ctx: T, callback: fn (T, u8) void) void {
        for (0..256) |i| {
            if (self.isSet(@intCast(i))) callback(ctx, @intCast(i));
        }
    }

    /// 槽位范围 → 异构类型（隐含映射）
    pub fn agentTypeForSlot(slot: u8) AgentType {
        if (slot < 64) return .cpu;      // 0-63: CPU
        if (slot < 128) return .gpu;     // 64-127: GPU
        if (slot < 192) return .fpga;    // 128-191: FPGA
        return .asic;                     // 192-255: ASIC
    }
};

/// 异构 agent 类型（由槽位范围隐含）
pub const AgentType = enum(u8) {
    cpu,
    gpu,
    fpga,
    asic,
};

/// 任务槽状态
pub const SlotState = enum(u8) {
    idle,       // 空闲
    pending,    // 待执行
    executing,  // 执行中
    completed,  // 已完成
    failed,     // 失败
};

/// 任务槽（256 个，静态数组，零堆分配）
pub const TaskSlot = struct {
    state: SlotState,
    task_id: u64,
    output: ?[]const u8,    // 成功输出（可为空）
    error_info: ?[]const u8, // 失败信息（可为空）

    pub fn init() TaskSlot {
        return .{
            .state = .idle,
            .task_id = 0,
            .output = null,
            .error_info = null,
        };
    }
};

/// 任务池（256 槽位，全局共享，90% 使用限制）
pub const TaskPool = struct {
    task_string: TaskString,
    slots: [constants.SLOT_COUNT]TaskSlot,
    active_count: u32,

    /// 最大活跃任务数（90% = 230）
    pub const USAGE_LIMIT: u32 = 230;

    pub fn init() TaskPool {
        return .{
            .task_string = TaskString.init(),
            .slots = [_]TaskSlot{TaskSlot.init()} ** constants.SLOT_COUNT,
            .active_count = 0,
        };
    }

    /// 是否可接受新任务（90% 限制）
    pub fn canAccept(self: TaskPool) bool {
        return self.active_count < USAGE_LIMIT;
    }

    /// 提交任务（设置位 + 标记槽位）
    pub fn submit(self: *TaskPool, slot: u8, task_id: u64) bool {
        if (!self.canAccept()) return false;
        self.task_string.set(slot);
        self.slots[slot].state = .pending;
        self.slots[slot].task_id = task_id;
        self.active_count += 1;
        return true;
    }

    /// 完成任务（清除位 + 标记槽位）
    pub fn complete(self: *TaskPool, slot: u8, output: ?[]const u8) void {
        self.task_string.clear(slot);
        self.slots[slot].state = .completed;
        self.slots[slot].output = output;
        if (self.active_count > 0) self.active_count -= 1;
    }

    /// 失败任务（清除位 + 标记槽位 + 记录错误）
    pub fn fail(self: *TaskPool, slot: u8, error_info: []const u8) void {
        self.task_string.clear(slot);
        self.slots[slot].state = .failed;
        self.slots[slot].error_info = error_info;
        if (self.active_count > 0) self.active_count -= 1;
    }
};

// ============================================================
// 测试
// ============================================================
const testing = @import("std").testing;

test "TaskString init all zero" {
    const ts = TaskString.init();
    try testing.expectEqual(@as(u32, 0), ts.popcount());
}

test "TaskString set and clear" {
    var ts = TaskString.init();
    ts.set(0);
    ts.set(64);
    ts.set(128);
    ts.set(255);
    try testing.expectEqual(@as(u32, 4), ts.popcount());
    try testing.expect(ts.isSet(0));
    try testing.expect(ts.isSet(64));
    try testing.expect(ts.isSet(128));
    try testing.expect(ts.isSet(255));

    ts.clear(0);
    try testing.expect(!ts.isSet(0));
    try testing.expectEqual(@as(u32, 3), ts.popcount());
}

test "TaskString findFirst/findNext" {
    var ts = TaskString.init();
    ts.set(5);
    ts.set(100);
    ts.set(200);

    try testing.expectEqual(@as(u8, 5), ts.findFirst().?);
    try testing.expectEqual(@as(u8, 100), ts.findNext(5).?);
    try testing.expectEqual(@as(u8, 200), ts.findNext(100).?);
    try testing.expect(ts.findNext(200) == null);
}

test "TaskString agentTypeForSlot" {
    try testing.expectEqual(AgentType.cpu, TaskString.agentTypeForSlot(0));
    try testing.expectEqual(AgentType.cpu, TaskString.agentTypeForSlot(63));
    try testing.expectEqual(AgentType.gpu, TaskString.agentTypeForSlot(64));
    try testing.expectEqual(AgentType.gpu, TaskString.agentTypeForSlot(127));
    try testing.expectEqual(AgentType.fpga, TaskString.agentTypeForSlot(128));
    try testing.expectEqual(AgentType.fpga, TaskString.agentTypeForSlot(191));
    try testing.expectEqual(AgentType.asic, TaskString.agentTypeForSlot(192));
    try testing.expectEqual(AgentType.asic, TaskString.agentTypeForSlot(255));
}

test "TaskPool submit and complete" {
    var pool = TaskPool.init();
    try testing.expect(pool.canAccept());

    try testing.expect(pool.submit(0, 1001));
    try testing.expect(pool.task_string.isSet(0));
    try testing.expectEqual(@as(u32, 1), pool.active_count);

    pool.complete(0, "output_data");
    try testing.expect(!pool.task_string.isSet(0));
    try testing.expectEqual(@as(u32, 0), pool.active_count);
}

test "TaskPool fail" {
    var pool = TaskPool.init();
    _ = pool.submit(5, 2001);
    pool.fail(5, "error: timeout");
    try testing.expect(!pool.task_string.isSet(5));
    try testing.expectEqual(SlotState.failed, pool.slots[5].state);
}

test "TaskPool 90% limit" {
    var pool = TaskPool.init();
    // 填满到 230（90% 限制）
    for (0..230) |i| {
        _ = pool.submit(@intCast(i), @intCast(i + 1));
    }
    try testing.expect(!pool.canAccept());
    // 第 231 个应该失败
    try testing.expect(!pool.submit(230, 9999));
}
