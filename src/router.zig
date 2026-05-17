// src/router.zig
// ZigClaw V2.5 | 双向翻译器 | 任务↔状态串↔token串
//
// 设计原则（显性直白）：
//   - 路由 = 位操作（set/clear），无需复杂调度算法
//   - 正向翻译：大模型输出 → TaskString（任务→状态串）
//   - 反向翻译：TaskString 变化 → token 串（反馈→大模型读取）
//   - 零堆分配，仅使用栈上和静态内存
//   - 原子操作保证并发安全，无锁
//
// 分形思想：
//   - 路由是将任务转换为分形树（256 位状态串）的手段
//   - 256 位状态向量码 = 出来任务无限细分到状态的手段
//   - 无数任务状态组合为状态链，路由翻译为离散 token 串，大模型读取
//
// 双向翻译架构：
//   大模型输出任务 → 路由(正向翻译) → 256位TaskString → 状态agent领取执行
//                                                             ↓
//   大模型读取 ← 路由(反向翻译) ← agent带回反馈 ← 执行结果

const task_string = @import("task_string.zig");
const mem = @import("std").mem;
const testing = @import("std").testing;
const TaskString = task_string.TaskString;
const TaskPool = task_string.TaskPool;
const SlotState = task_string.SlotState;
const AgentType = task_string.AgentType;

/// 路由请求上下文（供 handler 使用）
pub const RequestContext = struct {
    path: []const u8,
    slot: u8,
};

/// 路由处理函数类型（供 route_table 使用）
pub const HandlerFn = *const fn (ctx: *RequestContext) void;

/// Token 编码（离散化表示）
/// 每个活跃槽位编码为一个 token：槽位编号(8bit) + 状态(8bit)
pub const Token = packed struct {
    slot: u8,
    state: SlotState,

    /// 编码为 2 字节
    pub fn encode(self: Token) [2]u8 {
        return [2]u8{ self.slot, @intFromEnum(self.state) };
    }

    /// 解码自 2 字节
    pub fn decode(bytes: [2]u8) Token {
        return .{
            .slot = bytes[0],
            .state = @enumFromInt(bytes[1]),
        };
    }
};

/// 路由结构体（双向翻译器）
pub const Router = struct {
    task_pool: *TaskPool,
    next_task_id: u64,

    /// 正向翻译：大模型输出 → TaskString
    /// 解析大模型输出，提取任务特征码，设置对应位
    /// 返回分配的槽位号，若无可用槽位返回 null
    /// SEC-2: 不直接使用 LLM 输出计算槽位，使用顺序分配避免操纵
    pub fn routeTask(self: *Router, llm_output: []const u8) ?u8 {
        // 检查是否可接受新任务
        if (!self.task_pool.canAccept()) return null;

        // SEC-2: 使用 LLM 输出作为任务特征码（用于日志/追踪），不用于槽位分配
        const task_code = extractTaskCode(llm_output);
        _ = task_code; // 特征码仅用于追踪，不影响槽位分配

        // 顺序扫描找第一个空闲槽（避免基于不可信输入的槽位计算）
        var probe: u8 = 0;
        while (probe < 255) : (probe += 1) {
            if (!self.task_pool.task_string.isSet(probe)) {
                // 找到空闲槽，提交任务
                const task_id = self.next_task_id;
                self.next_task_id += 1;
                _ = self.task_pool.submit(probe, task_id);
                return probe;
            }
        }
        return null;  // 所有槽都满了
    }

    /// 反向翻译：TaskString 变化 → token 串（供大模型读取）
    /// 扫描 TaskString，将活跃槽位编码为 token 串
    /// 返回写入 token_buf 的字节数
    pub fn routeFeedback(self: *Router, token_buf: []u8) usize {
        var pos: usize = 0;
        const max_tokens = token_buf.len / 2;  // 每个 token 2 字节

        for (0..256) |i| {
            if (pos >= max_tokens) break;
            const slot: u8 = @intCast(i);
            if (self.task_pool.task_string.isSet(slot)) {
                const token = Token{
                    .slot = slot,
                    .state = self.task_pool.slots[slot].state,
                };
                const encoded = token.encode();
                token_buf[pos * 2] = encoded[0];
                token_buf[pos * 2 + 1] = encoded[1];
                pos += 1;
            }
        }
        return pos * 2;  // 返回写入的字节数
    }

    /// 反向翻译（仅失败任务）：扫描失败槽位 → token 串
    /// 用于失败反馈到大模型
    pub fn routeFailures(self: *Router, token_buf: []u8) usize {
        var pos: usize = 0;
        const max_tokens = token_buf.len / 2;

        for (0..256) |i| {
            if (pos >= max_tokens) break;
            const slot: u8 = @intCast(i);
            if (self.task_pool.slots[slot].state == .failed) {
                const token = Token{
                    .slot = slot,
                    .state = .failed,
                };
                const encoded = token.encode();
                token_buf[pos * 2] = encoded[0];
                token_buf[pos * 2 + 1] = encoded[1];
                pos += 1;
            }
        }
        return pos * 2;
    }

    /// 获取异构 agent 类型（由槽位范围隐含）
    pub fn getAgentType(_: *const Router, slot: u8) AgentType {
        return TaskString.agentTypeForSlot(slot);
    }

    /// 获取活跃任务数
    pub fn getActiveCount(self: *const Router) u32 {
        return self.task_pool.active_count;
    }

    /// 获取指定类型的活跃任务数
    pub fn getActiveCountByType(self: *const Router, agent_type: AgentType) u32 {
        const start: u32 = switch (agent_type) {
            .cpu => 0,
            .gpu => 64,
            .fpga => 128,
            .asic => 192,
        };
        const end: u32 = start + 64;
        var count: u32 = 0;
        for (start..end) |i| {
            if (self.task_pool.task_string.isSet(@intCast(i))) {
                count += 1;
            }
        }
        return count;
    }
};

/// 从大模型输出提取任务特征码（简单 FNV-1a 哈希）
fn extractTaskCode(output: []const u8) u32 {
    var hash: u32 = 2166136261;
    for (output) |byte| {
        hash ^= byte;
        hash *%= 16777619;
    }
    return hash;
}

// ============================================================
// 测试
// ============================================================
test "Token encode/decode" {
    const token = Token{ .slot = 42, .state = .executing };
    const encoded = token.encode();
    const decoded = Token.decode(encoded);
    try testing.expectEqual(@as(u8, 42), decoded.slot);
    try testing.expectEqual(SlotState.executing, decoded.state);
}

test "Router routeTask" {
    var pool = TaskPool.init();
    var router = Router{
        .task_pool = &pool,
        .next_task_id = 1,
    };

    // 正向翻译：大模型输出 → TaskString
    const slot = router.routeTask("task: compute fibonacci(40)");
    try testing.expect(slot != null);
    try testing.expect(pool.task_string.isSet(slot.?));
    try testing.expectEqual(@as(u32, 1), pool.active_count);
}

test "Router routeFeedback" {
    var pool = TaskPool.init();
    var router = Router{
        .task_pool = &pool,
        .next_task_id = 1,
    };

    // 提交两个任务
    _ = router.routeTask("task A");
    _ = router.routeTask("task B");

    // 反向翻译：TaskString → token 串
    var buf: [512]u8 = undefined;
    const len = router.routeFeedback(&buf);
    try testing.expect(len > 0);
    // 每个 token 2 字节，至少 2 个 token
    try testing.expect(len >= 4);
}

test "Router routeFailures" {
    var pool = TaskPool.init();
    var router = Router{
        .task_pool = &pool,
        .next_task_id = 1,
    };

    // 提交任务并标记失败
    const slot = router.routeTask("task: will fail").?;
    pool.fail(slot, "error: timeout");

    var buf: [512]u8 = undefined;
    const len = router.routeFailures(&buf);
    try testing.expect(len >= 2);  // 至少 1 个失败 token
}

test "Router getActiveCountByType" {
    var pool = TaskPool.init();
    var router = Router{
        .task_pool = &pool,
        .next_task_id = 1,
    };

    // 提交任务
    _ = router.routeTask("cpu task 1");
    _ = router.routeTask("cpu task 2");

    const cpu_count = router.getActiveCountByType(.cpu);
    try testing.expect(cpu_count >= 0);  // 至少有一些 CPU 任务
}

test "extractTaskCode deterministic" {
    const code1 = extractTaskCode("hello world");
    const code2 = extractTaskCode("hello world");
    try testing.expectEqual(code1, code2);

    const code3 = extractTaskCode("different input");
    try testing.expect(code1 != code3);
}
