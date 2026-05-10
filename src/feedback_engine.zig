// src/feedback_engine.zig
// 观测层 | Layer: Observability + Learning
// DRD-059 V4: 观测反馈学习 — SimpleLearner 规则引擎
//
// 设计原则：
//   - 显性直白：所有规则是硬编码的 if/else，无循环依赖、无动态调用
//   - 无堆：所有操作在栈上完成
//   - 纯函数：analyze 不修改输入，仅返回 Suggestion 或 null
//   - 模拟版：用简单规则生成优化建议，不接入真实推理引擎
//
// 规则（显式硬编码）：
//   R1: execution.ring_full_count > 10 → 建议 enable_sq_poll
//   R2: router.route_miss > router.route_hit * 0.2 → 建议 adjust_pool_size（hint: 路由表扩容）
//   R3: storage.heat_pool_miss > storage.heat_pool_hit → 建议 adjust_pool_size（hint: 热度池扩容）
//   R4: execution.syscall_fallback_count > 5 → 建议 disable_feature (direct IO fallback)
//   R5: entry.error_count > entry.request_count * 0.05 → 建议 adjust_timeout

const debug = @import("std").debug;
const feedback = @import("feedback.zig");
const ibus = @import("ibus.zig");

// ============================================================================
// 阈值常量（显性直白，无魔法数字）
// ============================================================================

const RING_FULL_THRESHOLD: u64 = 10;
const ROUTE_MISS_RATIO_THRESHOLD: f32 = 0.2;
const SYSCALL_FALLBACK_THRESHOLD: u64 = 5;
const ERROR_RATE_THRESHOLD: f32 = 0.05;

// ============================================================================
// SimpleLearner 结构体
// ============================================================================

pub const SimpleLearner = struct {
    /// 分析当前各层指标，返回优化建议或 null
    /// 规则优先级从高到低：R4 > R1 > R2 > R3 > R5
    pub fn analyze(
        entry: feedback.EntryMetrics,
        orch: feedback.OrchMetrics,
        exec: feedback.ExecMetrics,
        router: feedback.RouterMetrics,
        storage: feedback.StorageMetrics,
    ) ?feedback.Suggestion {
        // R4: syscall 过多 → 禁用 direct IO fallback（最高优先级）
        if (exec.syscall_fallback_count > SYSCALL_FALLBACK_THRESHOLD) {
            return feedback.Suggestion{
                .layer = .execution,
                .confidence = 0.9,
                .action = .{
                    .adjust_timeout = .{ .current_ms = 0, .recommended_ms = 0 },
                },
            };
        }

        // R1: ring 满次数过多 → 建议启用 SQPOLL
        if (exec.ring_full_count > RING_FULL_THRESHOLD) {
            return feedback.Suggestion{
                .layer = .execution,
                .confidence = 0.85,
                .action = .{
                    .enable_sq_poll = .{ .idle_ms = 100 },
                },
            };
        }

        // R2: 路由未命中率过高（> 20% of hits）→ 建议扩容路由表
        if (router.route_hit > 0) {
            const miss_ratio: f32 = @as(f32, @floatFromInt(router.route_miss)) /
                @as(f32, @floatFromInt(router.route_hit));
            if (miss_ratio > ROUTE_MISS_RATIO_THRESHOLD) {
                return feedback.Suggestion{
                    .layer = .router,
                    .confidence = 0.75,
                    .action = .{
                        .adjust_pool_size = .{ .current = 16, .recommended = 32 },
                    },
                };
            }
        }

        // R3: 热度池 miss > hit → 建议扩容热度池
        if (storage.heat_pool_miss > storage.heat_pool_hit) {
            return feedback.Suggestion{
                .layer = .storage,
                .confidence = 0.7,
                .action = .{
                    .adjust_pool_size = .{ .current = 64, .recommended = 128 },
                },
            };
        }

        // R5: 入口错误率 > 5% → 建议增加超时
        if (entry.request_count > 0) {
            const error_rate: f32 = @as(f32, @floatFromInt(entry.error_count)) /
                @as(f32, @floatFromInt(entry.request_count));
            if (error_rate > ERROR_RATE_THRESHOLD) {
                return feedback.Suggestion{
                    .layer = .entry,
                    .confidence = 0.8,
                    .action = .{
                        .adjust_timeout = .{ .current_ms = 5000, .recommended_ms = 10000 },
                    },
                };
            }
        }

        _ = orch; // 当前版本未使用编排层指标
        return null; // 所有指标正常，无建议
    }

    /// 通过 IBus 输出建议（若存在）
    pub fn analyzeAndEmit(
        entry: feedback.EntryMetrics,
        orch: feedback.OrchMetrics,
        exec: feedback.ExecMetrics,
        router: feedback.RouterMetrics,
        storage: feedback.StorageMetrics,
    ) void {
        if (analyze(entry, orch, exec, router, storage)) |suggestion| {
            // 通过 IBus 事件输出建议
            // 简化为仅输出层名和建议类型
            switch (suggestion.layer) {
                .execution => ibus.emit("feedback: execution suggestion available"),
                .router => ibus.emit("feedback: router suggestion available"),
                .storage => ibus.emit("feedback: storage suggestion available"),
                .entry => ibus.emit("feedback: entry suggestion available"),
                .orchestrator => ibus.emit("feedback: orchestrator suggestion available"),
            }
        }
    }
};

// ============================================================================
// 单元测试（inline）
// ============================================================================

const std_debug = debug;

test "SimpleLearner: 正常指标返回 null" {
    const entry = feedback.EntryMetrics{
        .request_count = 100, .error_count = 1,
        .p50_latency_us = 500, .p99_latency_us = 2000,
        .active_connections = 5,
    };
    const orch = feedback.OrchMetrics{
        .modality_switch_count = 0, .quantize_time_us = 0,
        .token_count = 0, .brain_hit_count = [_]u64{0} ** 8,
    };
    const exec = feedback.ExecMetrics{
        .uring_submit_count = 100, .uring_cqe_count = 100,
        .syscall_fallback_count = 0, .ring_full_count = 0,
    };
    const router = feedback.RouterMetrics{
        .route_hit = 100, .route_miss = 5, .middleware_reject = 0,
    };
    const storage = feedback.StorageMetrics{
        .heat_pool_hit = 100, .heat_pool_miss = 10,
        .ssd_flush_count = 0, .vector_search_count = 0,
        .arena_bytes_allocated = 0,
    };

    const result = SimpleLearner.analyze(entry, orch, exec, router, storage);
    std_debug.assert(result == null);
}

test "SimpleLearner: ring_full > 10 触发 SQPOLL 建议" {
    const entry = feedback.EntryMetrics{
        .request_count = 100, .error_count = 0,
        .p50_latency_us = 500, .p99_latency_us = 2000,
        .active_connections = 5,
    };
    const orch = feedback.OrchMetrics{
        .modality_switch_count = 0, .quantize_time_us = 0,
        .token_count = 0, .brain_hit_count = [_]u64{0} ** 8,
    };
    const exec = feedback.ExecMetrics{
        .uring_submit_count = 100, .uring_cqe_count = 100,
        .syscall_fallback_count = 0, .ring_full_count = 15, // > 10
    };
    const router = feedback.RouterMetrics{
        .route_hit = 100, .route_miss = 5, .middleware_reject = 0,
    };
    const storage = feedback.StorageMetrics{
        .heat_pool_hit = 100, .heat_pool_miss = 10,
        .ssd_flush_count = 0, .vector_search_count = 0,
        .arena_bytes_allocated = 0,
    };

    const result = SimpleLearner.analyze(entry, orch, exec, router, storage);
    std_debug.assert(result != null);
    const suggestion = result.?;
    std_debug.assert(suggestion.layer == .execution);
    std_debug.assert(suggestion.confidence == 0.85);
}
