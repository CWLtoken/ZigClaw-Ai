// src/worker.zig
// ZigClaw V2.5 | Worker 生命周期管理 | 5 状态 + 分裂计数 + TaskString 乱序扫描
//
// 设计原则（显性直白）：
//   - 状态转换显式可见，无隐式控制流
//   - 零堆分配，仅使用栈上和静态内存
//   - 原子操作保证并发安全，无锁
//   - Worker 乱序扫描 TaskString，无需调度器分配
//
// Worker 状态机：
//   idle → Acquire → execute → report → error
//                  ↓         ↓
//              (分裂)    (完成)
//                  ↓         ↓
//              Acquire    idle
//
// 乱序执行：
//   - Worker 从 TaskString 中任意选取有编号状态任务
//   - 无高低优先级，扫描顺序即执行顺序
//   - 成功：有输出，静默清除任务位
//   - 失败：有错误信息，清除任务位 + 记录失败原因

const constants = @import("constants.zig");
const task_string = @import("task_string.zig");
const cache_layer = @import("cache_layer.zig");
const TaskString = task_string.TaskString;
const TaskPool = task_string.TaskPool;
const SlotState = task_string.SlotState;
const L1Cache = cache_layer.L1Cache;

/// Worker 状态枚举（显性直白）
pub const WorkerState = enum(u8) {
    idle,      // 待命
    Acquire,   // 获取资源/任务
    execute,   // 执行中
    report,    // 反馈结果
    error,     // 出错/死亡
};

/// Worker 结构体（显性直白，无隐式字段）
pub const Worker = struct {
    id: u32,
    state: WorkerState,
    execute_count: u32,       // execute 分裂计数
    last_active_ts: u64,      // 最后活跃时间戳（用于超时检测）
    current_slot: u8,         // 当前执行的任务槽位（乱序扫描）
    scan_offset: u8,          // 扫描偏移（乱序起点）
    l1_cache: L1Cache,        // L1 本地缓存（从 L2 预取任务）

    pub fn init(id: u32) Worker {
        return .{
            .id = id,
            .state = .idle,
            .execute_count = 0,
            .last_active_ts = 0,
            .current_slot = 0,
            .scan_offset = 0,
            .l1_cache = L1Cache.init(),
        };
    }

    /// 状态转换：idle → Acquire（显式直白）
    pub fn acquire(self: *Worker) void {
        if (self.state == .idle) {
            self.state = .Acquire;
        }
    }

    /// 状态转换：Acquire → execute（显式直白）
    pub fn start_execute(self: *Worker) void {
        if (self.state == .Acquire) {
            self.state = .execute;
            self.execute_count += 1;
        }
    }

    /// 状态转换：execute → report（显式直白）
    pub fn report_result(self: *Worker) void {
        if (self.state == .execute) {
            self.state = .report;
        }
    }

    /// 状态转换：report → idle（显式直白）
    pub fn reset_idle(self: *Worker) void {
        if (self.state == .report) {
            self.state = .idle;
        }
    }

    /// 状态转换：→ error（显式直白）
    pub fn die(self: *Worker) void {
        self.state = .error;
    }

    /// 乱序扫描 TaskString，领取一个任务槽位
    pub fn acquireFromTaskString(self: *Worker, pool: *TaskPool) ?u8 {
        var slot: u8 = self.scan_offset;
        var attempts: u8 = 0;
        while (attempts < 256) : (attempts += 1) {
            if (pool.task_string.isSet(slot)) {
                self.current_slot = slot;
                self.state = .Acquire;
                pool.slots[slot].state = .executing;
                self.scan_offset = @intCast((slot + 1) % 256);
                return slot;
            }
            slot = @intCast((slot + 1) % 256);
        }
        return null;
    }

    /// 从 L1 缓存预取任务（流水第一步：L2 → L1）
    /// 返回预取的任务数
    pub fn prefetchFromL2(self: *Worker, pool: *TaskPool) u8 {
        return self.l1_cache.prefetch(&pool.task_string, self.scan_offset);
    }

    /// 流水执行：从 L1 取一个任务槽位
    /// 返回槽位号，若 L1 为空返回 null
    pub fn dequeueFromL1(self: *Worker) ?u8 {
        return self.l1_cache.dequeue();
    }

    /// L1 缓存是否为空
    pub fn l1IsEmpty(self: *const Worker) bool {
        return self.l1_cache.isEmpty();
    }

    /// 执行并报告结果（成功）
    pub fn reportSuccess(self: *Worker, pool: *TaskPool, output: ?[]const u8) void {
        const slot = self.current_slot;
        pool.complete(slot, output);
        self.state = .idle;
        self.current_slot = 0;
    }

    /// 执行并报告结果（失败）
    pub fn reportFailure(self: *Worker, pool: *TaskPool, error_info: []const u8) void {
        const slot = self.current_slot;
        pool.fail(slot, error_info);
        self.state = .idle;
        self.current_slot = 0;
    }

    /// 分裂计数 → 目标数量（显式直白）
    /// 第1次 execute：2 只 → 2 只（不变）
    /// 第2次 execute：3 只 → 4 只
    /// 第3次 execute：4 只 → 8 只
    /// 第4次 execute：5 只 → 16 只
    pub fn split_target(self: *const Worker) u32 {
        const count: u32 = self.execute_count;
        if (count <= 2) return 2;
        if (count == 3) return 4;
        if (count == 4) return 8;
        if (count == 5) return 16;
        return count;
    }

    /// 是否是活跃状态（非 error）
    pub fn is_active(self: *const Worker) bool {
        return self.state != .error;
    }

    /// 是否是待命状态
    pub fn is_idle(self: *const Worker) bool {
        return self.state == .idle;
    }
};

/// Worker 池（静态数组，零堆分配）
pub const WorkerPool = struct {
    workers: [constants.SLOT_COUNT]Worker,
    active_count: u32,      // 活跃 worker 数（非 error）
    idle_count: u32,        // 待命 worker 数
    next_id: u32,           // 下一个 worker ID

    /// 最小保留 agent 数
    const MIN_ACTIVE_AGENTS: u32 = 4;

    pub fn init() WorkerPool {
        var pool: WorkerPool = WorkerPool{
            .workers = undefined,
            .active_count = 0,
            .idle_count = 0,
            .next_id = 0,
        };
        // 初始化所有 worker 为 error（未激活）
        for (&pool.workers) |*w| {
            w.* = Worker.init(0);
            w.*.state = .error;
        }
        return pool;
    }

    /// 激活 N 个 worker（从 error → idle）
    pub fn activate(self: *WorkerPool, n: u32) u32 {
        var activated: u32 = 0;
        for (&self.workers) |*w| {
            if (activated >= n) break;
            if (w.state == .error) {
                w.id = self.next_id;
                self.next_id += 1;
                w.state = .idle;
                w.execute_count = 0;
                activated += 1;
                self.active_count += 1;
                self.idle_count += 1;
            }
        }
        return activated;
    }

    /// 尝试销毁一个 worker（idle → error）
    /// 返回是否成功（保留最小数量）
    pub fn try_kill_idle(self: *WorkerPool) bool {
        // 显性直白：保留最小数量检查
        if (self.active_count <= MIN_ACTIVE_AGENTS) {
            return false;  // 不能销毁
        }
        for (&self.workers) |*w| {
            if (w.state == .idle) {
                w.state = .error;
                self.active_count -= 1;
                self.idle_count -= 1;
                return true;
            }
        }
        return false;
    }

    /// 无任务时自动销毁多余 idle worker
    pub fn auto_kill_idle(self: *WorkerPool) u32 {
        var killed: u32 = 0;
        // 显性直白：循环直到达到最小保留数
        while (self.active_count > MIN_ACTIVE_AGENTS) {
            if (!self.try_kill_idle()) break;
            killed += 1;
        }
        return killed;
    }
};
