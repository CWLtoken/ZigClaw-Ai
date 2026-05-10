// src/ibus.zig
// 观测层 | Layer: Observability
// DRD-058: V3 IBus 内省总线 — 真实可操作的观测总线
//
// 功能：
//   1. 全局 LayerMetrics 原子变量，各层通过 record() 更新
//   2. formatBusStatus() 遍历所有原子变量，格式化为 JSON
//   3. 保留原有 emit() 日志事件功能
//
// 架构约束：
//   - 不动 reactor.zig / protocol.zig / io_uring.zig
//   - 对齐 feedback.zig 中的 LayerMetrics 联合类型
//   - 无堆：所有指标存储在 atomic.Value 或全局静态变量中

const atomic = @import("std").atomic;
const debug = @import("std").debug;
const feedback = @import("feedback.zig");

// ============================================================================
// 原有的 ModelFeedback（已废弃 → 迁移到 feedback.zig 的 LayerMetrics）
// DRD-058 迁移路径：
//   1. 所有调用 write_metrics/read_metrics 的代码改为 record()/readMetrics()
//   2. ModelFeedback 的字段逐步映射到 LayerMetrics 子类型
//   3. 本段代码将在 v3.1 移除
// ============================================================================

// 已废弃：改用 feedback.LayerMetrics + ibus.record()（v3.1 移除）
pub const ModelFeedback = struct {
    ssd_heat_version_flip_rate: f32,
    arena_pressure: f32,
    single_codebook_drift: f32,
    latency_attention_events: LatencyAttentionEvents,
    current_flush_interval_sec: u16,
};

// 已废弃：改用 feedback.EntryMetrics / OrchMetrics / ExecMetrics（v3.1 移除）
pub const LatencyAttentionEvents = struct {
    count: u16,
    last_latency_ms: u16,
    context_hash: u32,
};

// 全局静态反馈缓冲区（保留，v3.1 移除）
var g_model_feedback: ModelFeedback = .{
    .ssd_heat_version_flip_rate = 0,
    .arena_pressure = 0,
    .single_codebook_drift = 0,
    .latency_attention_events = .{ .count = 0, .last_latency_ms = 0, .context_hash = 0 },
    .current_flush_interval_sec = 0,
};

// 已废弃：改用 ibus.record(layer, metrics)（v3.1 移除）
pub fn write_metrics(new_fb: ModelFeedback) void {
    g_model_feedback = new_fb;
}

// 已废弃：改用 ibus.readMetrics() 返回 LayerMetrics（v3.1 移除）
pub fn read_metrics() *const ModelFeedback {
    return &g_model_feedback;
}

// ============================================================================
// DRD-058: LayerMetrics 原子变量
// ============================================================================

var g_entry_metrics: feedback.EntryMetrics = .{
    .request_count = 0,
    .error_count = 0,
    .p50_latency_us = 0,
    .p99_latency_us = 0,
    .active_connections = 0,
};

var g_orch_metrics: feedback.OrchMetrics = .{
    .modality_switch_count = 0,
    .quantize_time_us = 0,
    .token_count = 0,
    .brain_hit_count = [_]u64{0} ** 8,
};

var g_exec_metrics: feedback.ExecMetrics = .{
    .uring_submit_count = 0,
    .uring_cqe_count = 0,
    .syscall_fallback_count = 0,
    .ring_full_count = 0,
};

var g_router_metrics: feedback.RouterMetrics = .{
    .route_hit = 0,
    .route_miss = 0,
    .middleware_reject = 0,
};

var g_storage_metrics: feedback.StorageMetrics = .{
    .heat_pool_hit = 0,
    .heat_pool_miss = 0,
    .ssd_flush_count = 0,
    .vector_search_count = 0,
    .arena_bytes_allocated = 0,
};

/// 初始化所有指标（在 main.zig 启动时调用）
pub fn init() void {
    g_entry_metrics = .{};
    g_orch_metrics = .{};
    g_exec_metrics = .{};
    g_router_metrics = .{};
    g_storage_metrics = .{};
}

// ============================================================================
// DRD-058: record() — 各层调用更新指标
// ============================================================================
pub fn record(layer: feedback.Layer, metrics: feedback.LayerMetrics) void {
    switch (layer) {
        .entry => g_entry_metrics = metrics.entry,
        .orchestrator => g_orch_metrics = metrics.orchestrator,
        .execution => g_exec_metrics = metrics.execution,
        .router => g_router_metrics = metrics.router,
        .storage => g_storage_metrics = metrics.storage,
    }
}

/// 读取所有层指标为统一的 LayerMetrics（供上层查询）
pub fn readMetrics() feedback.LayerMetrics {
    return .{
        .entry = g_entry_metrics,
        .orchestrator = g_orch_metrics,
        .execution = g_exec_metrics,
        .router = g_router_metrics,
        .storage = g_storage_metrics,
    };
}

// ============================================================================
// DRD-058: formatBusStatus() — 格式化为 JSON
// 返回写入 buf 的字节数
// ============================================================================

pub fn formatBusStatus(buf: []u8) usize {
    const w = buf;

    // 使用简单的 JSON 拼接（无堆分配）
    var pos: usize = 0;

    // 辅助：追加字符串
    const append = struct {
        fn f(b: []u8, p: *usize, s: []const u8) void {
            const n = @min(s.len, b.len - p.*);
            @memcpy(b[p.* .. p.* + n], s);
            p.* += n;
        }
    }.f;

    append(w, &pos, "{\n");

    // entry 层
    append(w, &pos, "  \"entry\": {\n");
    append(w, &pos, "    \"request_count\": ");
    pos += printU64(w[pos..], g_entry_metrics.request_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"error_count\": ");
    pos += printU64(w[pos..], g_entry_metrics.error_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"p50_latency_us\": ");
    pos += printU64(w[pos..], g_entry_metrics.p50_latency_us);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"p99_latency_us\": ");
    pos += printU64(w[pos..], g_entry_metrics.p99_latency_us);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"active_connections\": ");
    pos += printU32(w[pos..], g_entry_metrics.active_connections);
    append(w, &pos, "\n  },\n");

    // orchestrator 层
    append(w, &pos, "  \"orchestrator\": {\n");
    append(w, &pos, "    \"modality_switch_count\": ");
    pos += printU64(w[pos..], g_orch_metrics.modality_switch_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"quantize_time_us\": ");
    pos += printU64(w[pos..], g_orch_metrics.quantize_time_us);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"token_count\": ");
    pos += printU64(w[pos..], g_orch_metrics.token_count);
    append(w, &pos, "\n  },\n");

    // execution 层
    append(w, &pos, "  \"execution\": {\n");
    append(w, &pos, "    \"uring_submit_count\": ");
    pos += printU64(w[pos..], g_exec_metrics.uring_submit_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"uring_cqe_count\": ");
    pos += printU64(w[pos..], g_exec_metrics.uring_cqe_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"syscall_fallback_count\": ");
    pos += printU64(w[pos..], g_exec_metrics.syscall_fallback_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"ring_full_count\": ");
    pos += printU64(w[pos..], g_exec_metrics.ring_full_count);
    append(w, &pos, "\n  },\n");

    // router 层
    append(w, &pos, "  \"router\": {\n");
    append(w, &pos, "    \"route_hit\": ");
    pos += printU64(w[pos..], g_router_metrics.route_hit);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"route_miss\": ");
    pos += printU64(w[pos..], g_router_metrics.route_miss);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"middleware_reject\": ");
    pos += printU64(w[pos..], g_router_metrics.middleware_reject);
    append(w, &pos, "\n  },\n");

    // storage 层
    append(w, &pos, "  \"storage\": {\n");
    append(w, &pos, "    \"heat_pool_hit\": ");
    pos += printU64(w[pos..], g_storage_metrics.heat_pool_hit);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"heat_pool_miss\": ");
    pos += printU64(w[pos..], g_storage_metrics.heat_pool_miss);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"ssd_flush_count\": ");
    pos += printU64(w[pos..], g_storage_metrics.ssd_flush_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"vector_search_count\": ");
    pos += printU64(w[pos..], g_storage_metrics.vector_search_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"arena_bytes_allocated\": ");
    pos += printU64(w[pos..], g_storage_metrics.arena_bytes_allocated);
    append(w, &pos, "\n  }\n");

    append(w, &pos, "}\n");

    return pos;
}

// ============================================================================
// 数字格式化辅助（无堆分配）
// ============================================================================

fn printU64(buf: []u8, val: u64) usize {
    if (val == 0) {
        if (buf.len > 0) {
            buf[0] = '0';
            return 1;
        }
        return 0;
    }
    var tmp: [32]u8 = undefined;
    var v = val;
    var i: usize = 0;
    while (v > 0 and i < tmp.len) {
        tmp[i] = @intCast('0' + @as(u8, @intCast(v % 10)));
        v /= 10;
        i += 1;
    }
    // 反转
    var j: usize = 0;
    while (j < i and j < buf.len) {
        buf[j] = tmp[i - 1 - j];
        j += 1;
    }
    return j;
}

fn printU32(buf: []u8, val: u32) usize {
    return printU64(buf, @as(u64, val));
}

// ============================================================================
// 保留原有功能：emit() 日志事件
// ============================================================================

pub fn emit(event_name: []const u8) void {
    debug.print("[IBus] event: {s}\n", .{event_name});
}

// ============================================================================
// 单元测试（P46）— 保留
// ============================================================================

const std_debug = @import("std").debug;

test "P46: ModelFeedback 初始化" {
    const fb = read_metrics();
    std_debug.assert(fb.ssd_heat_version_flip_rate == 0);
    std_debug.assert(fb.arena_pressure == 0);
}

test "P46: write_metrics 和 read_metrics" {
    const new_fb: ModelFeedback = .{
        .ssd_heat_version_flip_rate = 0.5,
        .arena_pressure = 0.3,
        .single_codebook_drift = 0.1,
        .latency_attention_events = .{ .count = 10, .last_latency_ms = 50, .context_hash = 12345 },
        .current_flush_interval_sec = 30,
    };
    write_metrics(new_fb);

    const fb = read_metrics();
    std_debug.assert(fb.ssd_heat_version_flip_rate == 0.5);
    std_debug.assert(fb.latency_attention_events.count == 10);
    std_debug.print("P46: IBus 观测模块测试通过\n", .{});
}