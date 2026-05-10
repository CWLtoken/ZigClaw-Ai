// src/integration_p56.zig
// DRD-059 V4: 观测反馈学习 — SimpleLearner 集成测试
// 测试策略：
//   1. 注入高 ring 满指标 → 验证建议启用 SQPOLL
//   2. 注入正常指标 → 验证无建议返回 null
//   3. 多次调用 analyze 不崩溃，且建议内容符合预期格式

const fe = @import("feedback_engine.zig");
const feedback = @import("feedback.zig");

// ============================================================================
// 测试 1: 注入高 ring_full 指标 → 建议启用 SQPOLL
// ============================================================================

test "P56-1: 高 ring_full → SQPOLL 建议" {
    const entry = feedback.EntryMetrics{
        .request_count = 100,
        .error_count = 0,
        .p50_latency_us = 500,
        .p99_latency_us = 2000,
        .active_connections = 5,
    };
    const orch = feedback.OrchMetrics{
        .modality_switch_count = 0,
        .quantize_time_us = 0,
        .token_count = 0,
        .brain_hit_count = [_]u64{0} ** 8,
    };
    const exec = feedback.ExecMetrics{
        .uring_submit_count = 100,
        .uring_cqe_count = 100,
        .syscall_fallback_count = 0,
        .ring_full_count = 15, // > 阈值 10
    };
    const router = feedback.RouterMetrics{
        .route_hit = 100,
        .route_miss = 5,
        .middleware_reject = 0,
    };
    const storage = feedback.StorageMetrics{
        .heat_pool_hit = 100,
        .heat_pool_miss = 10,
        .ssd_flush_count = 0,
        .vector_search_count = 0,
        .arena_bytes_allocated = 0,
    };

    const result = fe.SimpleLearner.analyze(entry, orch, exec, router, storage);
    @import("std").debug.assert(result != null);

    const suggestion = result.?;
    @import("std").debug.assert(suggestion.layer == .execution);
    @import("std").debug.assert(suggestion.confidence == 0.85);
    // 验证是 enable_sq_poll 建议
    @import("std").debug.assert(suggestion.action == .enable_sq_poll);

    @import("std").debug.print("P56-1: 高 ring_full → SQPOLL 建议 通过\n", .{});
}

// ============================================================================
// 测试 2: 正常指标 → 无建议返回 null
// ============================================================================

test "P56-2: 正常指标 → null" {
    const entry = feedback.EntryMetrics{
        .request_count = 100,
        .error_count = 1, // 1% 错误率，低于 5% 阈值
        .p50_latency_us = 500,
        .p99_latency_us = 2000,
        .active_connections = 5,
    };
    const orch = feedback.OrchMetrics{
        .modality_switch_count = 0,
        .quantize_time_us = 0,
        .token_count = 0,
        .brain_hit_count = [_]u64{0} ** 8,
    };
    const exec = feedback.ExecMetrics{
        .uring_submit_count = 100,
        .uring_cqe_count = 100,
        .syscall_fallback_count = 0,
        .ring_full_count = 0, // 低于阈值
    };
    const router = feedback.RouterMetrics{
        .route_hit = 100,
        .route_miss = 5, // 5% 未命中率，低于 20% 阈值
        .middleware_reject = 0,
    };
    const storage = feedback.StorageMetrics{
        .heat_pool_hit = 100,
        .heat_pool_miss = 10, // hit > miss
        .ssd_flush_count = 0,
        .vector_search_count = 0,
        .arena_bytes_allocated = 0,
    };

    const result = fe.SimpleLearner.analyze(entry, orch, exec, router, storage);
    @import("std").debug.assert(result == null);

    @import("std").debug.print("P56-2: 正常指标 → null 通过\n", .{});
}

// ============================================================================
// 测试 3: 多次调用 analyze 不崩溃 + 建议格式验证
// ============================================================================

test "P56-3: 多次调用不崩溃 + 路由高未命中 → router 建议" {
    // 第一次：高路由未命中率
    const entry = feedback.EntryMetrics{
        .request_count = 100,
        .error_count = 0,
        .p50_latency_us = 500,
        .p99_latency_us = 2000,
        .active_connections = 5,
    };
    const orch = feedback.OrchMetrics{
        .modality_switch_count = 0,
        .quantize_time_us = 0,
        .token_count = 0,
        .brain_hit_count = [_]u64{0} ** 8,
    };
    const exec = feedback.ExecMetrics{
        .uring_submit_count = 100,
        .uring_cqe_count = 100,
        .syscall_fallback_count = 0,
        .ring_full_count = 0,
    };
    const router_high_miss = feedback.RouterMetrics{
        .route_hit = 10,
        .route_miss = 5, // 50% > 20% 阈值
        .middleware_reject = 0,
    };
    const storage = feedback.StorageMetrics{
        .heat_pool_hit = 100,
        .heat_pool_miss = 10,
        .ssd_flush_count = 0,
        .vector_search_count = 0,
        .arena_bytes_allocated = 0,
    };

    // 调用 1：高路由未命中
    const r1 = fe.SimpleLearner.analyze(entry, orch, exec, router_high_miss, storage);
    @import("std").debug.assert(r1 != null);
    @import("std").debug.assert(r1.?.layer == .router);
    @import("std").debug.assert(r1.?.confidence == 0.75);

    // 调用 2：正常指标
    const router_normal = feedback.RouterMetrics{
        .route_hit = 100,
        .route_miss = 5,
        .middleware_reject = 0,
    };
    const r2 = fe.SimpleLearner.analyze(entry, orch, exec, router_normal, storage);
    @import("std").debug.assert(r2 == null);

    // 调用 3：高错误率
    const entry_high_err = feedback.EntryMetrics{
        .request_count = 100,
        .error_count = 10, // 10% > 5%
        .p50_latency_us = 500,
        .p99_latency_us = 2000,
        .active_connections = 5,
    };
    const r3 = fe.SimpleLearner.analyze(entry_high_err, orch, exec, router_normal, storage);
    @import("std").debug.assert(r3 != null);
    @import("std").debug.assert(r3.?.layer == .entry);
    @import("std").debug.assert(r3.?.confidence == 0.8);

    // 调用 4：analyzeAndEmit 不崩溃
    fe.SimpleLearner.analyzeAndEmit(entry, orch, exec, router_high_miss, storage);
    fe.SimpleLearner.analyzeAndEmit(entry, orch, exec, router_normal, storage);

    @import("std").debug.print("P56-3: 多次调用不崩溃 + 路由建议 通过\n", .{});
}
