// src/scheduler.zig
// ZigClaw V2.5 | 集中式调度器 | 任务队列 + 分裂策略 + 系统监控
//
// 设计原则（显性直白）：
//   - 调度层与执行层分离，不污染 reactor/protocol
//   - 零堆分配，仅使用栈上和静态内存
//   - 原子操作保证并发安全，无锁
//   - 状态转换显式可见，无隐式控制流
//
// 调度策略：
//   - 任务发布：入队 → 分配 idle worker → Acquire → execute
//   - 分裂策略：execute_count 决定目标数量，系统占用 ≥70% 停止
//   - 自动回收：无任务时 idle → error，保留最少 4 只

const std = @import("std");
const worker = @import("worker.zig");
const WorkerState = worker.WorkerState;
const WorkerPool = worker.WorkerPool;

/// 最大任务数（静态数组，零堆分配）
pub const MAX_TASKS: usize = 1024;

/// 任务结构体（显性直白）
pub const Task = struct {
    id: u64,
    op_code: u8,
    data_ptr: ?*anyopaque,
    data_len: u32,
    assigned_worker_id: u32,
    state: TaskState,

    pub fn init(id: u64, op_code: u8, data_ptr: ?*anyopaque, data_len: u32) Task {
        return .{
            .id = id,
            .op_code = op_code,
            .data_ptr = data_ptr,
            .data_len = data_len,
            .assigned_worker_id = 0,
            .state = .pending,
        };
    }
};

/// 任务状态（显性直白）
pub const TaskState = enum(u8) {
    pending,    // 待分配
    assigned,   // 已分配给 worker
    executing,  // 执行中
    completed,  // 已完成
    failed,     // 失败
};

/// 调度器结构体（显性直白）
pub const Scheduler = struct {
    task_queue: [MAX_TASKS]Task,
    task_head: u32,          // 队列头
    task_tail: u32,          // 队列尾
    task_count: u32,         // 当前任务数
    worker_pool: WorkerPool,
    next_task_id: u64,
    total_executed: u64,     // 总执行计数
    total_split: u64,        // 总分裂计数

    /// 系统占用阈值（70%）
    const SYS_USAGE_THRESHOLD: u32 = 70;

    /// 最小保留 agent 数
    const MIN_ACTIVE_AGENTS: u32 = 4;

    pub fn init() Scheduler {
        return .{
            .task_queue = undefined,
            .task_head = 0,
            .task_tail = 0,
            .task_count = 0,
            .worker_pool = WorkerPool.init(),
            .next_task_id = 1,
            .total_executed = 0,
            .total_split = 0,
        };
    }

    /// 发布任务（显式直白）
    pub fn submit_task(self: *Scheduler, op_code: u8, data_ptr: ?*anyopaque, data_len: u32) SubmitResult {
        // 队列满检查
        if (self.task_count >= MAX_TASKS) {
            return .queue_full;
        }
        const task_id = self.next_task_id;
        self.next_task_id += 1;
        self.task_queue[self.task_tail] = Task.init(task_id, op_code, data_ptr, data_len);
        self.task_tail = (self.task_tail + 1) % MAX_TASKS;
        self.task_count += 1;
        return .{ .ok = task_id };
    }
    pub const SubmitResult = union(enum) {
        ok: u64,
        queue_full,
    };

    /// 调度一步（显式直白）
    pub fn tick(self: *Scheduler, sys_usage_percent: u32) TickResult {
        var result = TickResult{};

        // 步骤1：分配任务给 idle worker
        result.assigned = self.assign_pending_tasks();

        // 步骤2：检查分裂条件
        result.split = self.check_split(sys_usage_percent);

        // 步骤3：回收多余 idle worker
        result.killed = self.reclaim_idle_workers();

        return result;
    }
    pub const TickResult = struct {
        assigned: u32,
        split: u32,
        killed: u32,
    };

    /// 分配待处理任务给 idle worker（显式直白）
    fn assign_pending_tasks(self: *Scheduler) u32 {
        var assigned: u32 = 0;
        // 遍历任务队列
        var i = self.task_head;
        var remaining = self.task_count;
        while (remaining > 0) : (remaining -= 1) {
            var task = &self.task_queue[i];
            if (task.state == .pending) {
                // 查找 idle worker
                if (self.find_and_assign_idle_worker(task)) {
                    assigned += 1;
                }
            }
            i = (i + 1) % MAX_TASKS;
        }
        return assigned;
    }

    /// 查找 idle worker 并分配任务（显式直白）
    fn find_and_assign_idle_worker(self: *Scheduler, task: *Task) bool {
        for (&self.worker_pool.workers) |*w| {
            if (w.state == .idle and w.is_active()) {
                task.assigned_worker_id = w.id;
                task.state = .assigned;
                w.acquire();
                return true;
            }
        }
        return false;
    }

    /// 检查分裂条件（显式直白）
    fn check_split(self: *Scheduler, sys_usage_percent: u32) u32 {
        // 系统占用 ≥ 70%：停止分裂
        if (sys_usage_percent >= SYS_USAGE_THRESHOLD) {
            return 0;
        }
        var total_split: u32 = 0;
        // 遍历所有活跃 worker
        for (&self.worker_pool.workers) |*w| {
            if (w.state == .execute and w.is_active()) {
                const target = w.split_target();
                if (target > self.worker_pool.active_count) {
                    const to_add = target - self.worker_pool.active_count;
                    const activated = self.worker_pool.activate(to_add);
                    self.total_split += activated;
                    total_split += activated;
                }
            }
        }
        return total_split;
    }

    /// 回收多余 idle worker（显式直白）
    fn reclaim_idle_workers(self: *Scheduler) u32 {
        // 无任务时自动销毁
        if (self.task_count == 0) {
            return self.worker_pool.auto_kill_idle();
        }
        return 0;
    }

    /// 获取待命 worker 数量（显式直白）
    pub fn get_idle_count(self: *const Scheduler) u32 {
        return self.worker_pool.idle_count;
    }

    /// 获取活跃 worker 数量（显式直白）
    pub fn get_active_count(self: *const Scheduler) u32 {
        return self.worker_pool.active_count;
    }

    /// 初始化激活 N 个 worker（显式直白）
    pub fn bootstrap_agents(self: *Scheduler, n: u32) u32 {
        return self.worker_pool.activate(n);
    }
};
