// src/integration_p55.zig
// DRD-058: V3 IBus 内省总线 — 集成测试
// 测试策略：
//   1. 指标 record + read 验证
//   2. IBus 端点 /ibus JSON 输出包含 "execution" 和 "router" 段
//   3. emit() 不崩溃

const ibus = @import("ibus.zig");
const feedback = @import("feedback.zig");

// ============================================================================
// 测试 1: 指标记录 — record(.execution, ...) 后读取验证
// ============================================================================

test "P55-1: record execution metrics — 更新后读取正确" {
    // 构造 ExecMetrics
    const exec_m: feedback.ExecMetrics = .{
        .uring_submit_count = 42,
        .uring_cqe_count = 40,
        .syscall_fallback_count = 2,
        .ring_full_count = 1,
    };

    // 使用 LayerMetrics union 包装
    const layer_m = feedback.LayerMetrics{ .execution = exec_m };
    ibus.record(.execution, layer_m);

    // 通过 formatBusStatus 间接验证（或直接用公开变量）
    // 由于没有 getter，使用零长度缓冲区调用 formatBusStatus 确认不崩溃
    var buf: [2048]u8 = undefined;
    const len = ibus.formatBusStatus(&buf);
    @import("std").debug.assert(len > 0);

    // 检查输出包含 "uring_submit_count"
    const output = buf[0..len];
    @import("std").debug.assert(@import("std").mem.indexOf(u8, output, "uring_submit_count") != null);
    @import("std").debug.assert(@import("std").mem.indexOf(u8, output, "\"uring_submit_count\": 42") != null);

    @import("std").debug.print("P55-1: record execution metrics 通过\n", .{});
}

// ============================================================================
// 测试 2: IBus 端点输出 — JSON 字符串包含 "execution" 和 "router" 段
// ============================================================================

test "P55-2: formatBusStatus JSON — 包含 execution 和 router 段" {
    // 设置各层指标
    const entry_m = feedback.LayerMetrics{
        .entry = .{
            .request_count = 100,
            .error_count = 3,
            .p50_latency_us = 500,
            .p99_latency_us = 2000,
            .active_connections = 5,
        },
    };
    ibus.record(.entry, entry_m);

    const router_m = feedback.LayerMetrics{
        .router = .{
            .route_hit = 80,
            .route_miss = 5,
            .middleware_reject = 2,
        },
    };
    ibus.record(.router, router_m);

    // 格式化
    var buf: [2048]u8 = undefined;
    const len = ibus.formatBusStatus(&buf);
    @import("std").debug.assert(len > 0);

    const output = buf[0..len];

    // 验证包含 "execution" 段
    @import("std").debug.assert(@import("std").mem.indexOf(u8, output, "\"execution\"") != null);

    // 验证包含 "router" 段
    @import("std").debug.assert(@import("std").mem.indexOf(u8, output, "\"router\"") != null);

    // 验证包含 entry 数据
    @import("std").debug.assert(@import("std").mem.indexOf(u8, output, "\"request_count\"") != null);

    // 验证包含 router 数据
    @import("std").debug.assert(@import("std").mem.indexOf(u8, output, "\"route_hit\": 80") != null);

    @import("std").debug.print("P55-2: formatBusStatus JSON 通过\n", .{});
}

// ============================================================================
// 测试 3: 事件发射 — emit() 输出不崩溃
// ============================================================================

test "P55-3: emit 事件发射 — 不崩溃" {
    // 简单调用 emit，确认不崩溃
    ibus.emit("test_event");
    ibus.emit("system_ready");
    ibus.emit("");

    // 如果执行到这里，说明没有崩溃
    @import("std").debug.print("P55-3: emit 事件发射 通过\n", .{});
}
