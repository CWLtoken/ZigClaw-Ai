// src/metrics.zig
// 观测层 | Layer: Observability
// 无锁原子指标收集，用于 Prometheus 格式导出

const std = @import("std");

// 核心指标（静态原子变量）
// WARNING: single-thread only; use atomics for multi-thread
pub var http_requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// WARNING: single-thread only; use atomics for multi-thread
pub var auth_failures_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// WARNING: single-thread only; use atomics for multi-thread
pub var infer_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
// WARNING: single-thread only; use atomics for multi-thread
pub var active_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

// P49：推理延迟直方图（分桶，单位 ms）
// 分桶边界：10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, +Inf
pub const LATENCY_BUCKETS = [_]f64{ 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 };
const NUM_BUCKETS = LATENCY_BUCKETS.len + 1; // +1 for +Inf bucket

// 每个桶的计数器（静态数组，在 initLatencyBuckets 中初始化）
// WARNING: single-thread only; buckets_initialized is not atomic
pub var infer_latency_buckets: [NUM_BUCKETS]std.atomic.Value(u64) = undefined;
var buckets_initialized: bool = false;  // WARNING: not atomic, single-thread only

// 初始化桶计数器（在程序启动时调用一次）
pub fn initLatencyBuckets() void {
    if (buckets_initialized) return;
    for (&infer_latency_buckets) |*bucket| {
        bucket.* = std.atomic.Value(u64).init(0);
    }
    buckets_initialized = true;
}

// 记录推理延迟（单位 ms）
pub fn observeInferLatency(latency_ms: f64) void {
    // 确保桶已初始化
    if (!buckets_initialized) initLatencyBuckets();
    
    // 找到对应的桶
    for (LATENCY_BUCKETS, 0..) |boundary, i| {
        if (latency_ms <= boundary) {
            _ = infer_latency_buckets[i].fetchAdd(1, .monotonic);
            return;
        }
    }
    // 大于所有边界，放入 +Inf 桶
    _ = infer_latency_buckets[NUM_BUCKETS - 1].fetchAdd(1, .monotonic);
}

// P49：io_uring 操作计数
pub var uring_accept_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var uring_read_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var uring_write_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

pub fn incrUringAccept() void {
    _ = uring_accept_total.fetchAdd(1, .monotonic);
}

pub fn incrUringRead() void {
    _ = uring_read_total.fetchAdd(1, .monotonic);
}

pub fn incrUringWrite() void {
    _ = uring_write_total.fetchAdd(1, .monotonic);
}

// P49：窗口槽位使用率（占位，后续从 io_uring 获取）
pub var uring_sq_ring_used: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);
pub var uring_cq_ring_used: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

pub fn setSqRingUsed(n: u32) void {
    uring_sq_ring_used.store(n, .release);
}

pub fn setCqRingUsed(n: u32) void {
    uring_cq_ring_used.store(n, .release);
}

// 递增函数（调用方在入口层）
pub fn incrHttpRequests() void {
    _ = http_requests_total.fetchAdd(1, .monotonic);
}

pub fn incrAuthFailures() void {
    _ = auth_failures_total.fetchAdd(1, .monotonic);
}

pub fn incrInfer() void {
    _ = infer_total.fetchAdd(1, .monotonic);
}

pub fn incrActiveConnections() void {
    _ = active_connections.fetchAdd(1, .monotonic);
}

pub fn decrActiveConnections() void {
    _ = active_connections.fetchSub(1, .monotonic);
}

// Prometheus 格式输出（写入给定缓冲区，返回写入字节数）
// 调用方提供缓冲区（建议 1024 字节以上，因为新增指标）
pub fn formatMetrics(buf: []u8) usize {
    // 确保桶已初始化
    if (!buckets_initialized) initLatencyBuckets();
    
    const http = http_requests_total.load(.acquire);
    const auth = auth_failures_total.load(.acquire);
    const infer = infer_total.load(.acquire);
    const active = active_connections.load(.acquire);
    const accept_total = uring_accept_total.load(.acquire);
    const read_total = uring_read_total.load(.acquire);
    const write_total = uring_write_total.load(.acquire);
    const sq_used = uring_sq_ring_used.load(.acquire);
    const cq_used = uring_cq_ring_used.load(.acquire);

    // 构建延迟直方图的 bucket 行
    var bucket_lines: [1024]u8 = undefined;
    var bucket_len: usize = 0;
    
    // 计算累积和
    var cumulative: u64 = 0;
    for (LATENCY_BUCKETS, 0..) |boundary, i| {
        const bucket_val = infer_latency_buckets[i].load(.acquire);
        cumulative += bucket_val;
        const line = std.fmt.bufPrint(bucket_lines[bucket_len..], 
            "zigclaw_infer_latency_ms_bucket{{le=\"{d}\"}} {d}\n", 
            .{ boundary, cumulative }) catch unreachable;
        bucket_len += line.len;
    }
    // +Inf 桶
    const inf_bucket = infer_latency_buckets[NUM_BUCKETS - 1].load(.acquire);
    cumulative += inf_bucket;
    const inf_line = std.fmt.bufPrint(bucket_lines[bucket_len..], 
        "zigclaw_infer_latency_ms_bucket{{le=\"+Inf\"}} {d}\n", 
        .{cumulative}) catch unreachable;
    bucket_len += inf_line.len;

    const result = std.fmt.bufPrint(buf,
        \\# HELP zigclaw_http_requests_total Total HTTP requests
        \\# TYPE zigclaw_http_requests_total counter
        \\zigclaw_http_requests_total {d}
        \\# HELP zigclaw_auth_failures_total Authentication failures
        \\# TYPE zigclaw_auth_failures_total counter
        \\zigclaw_auth_failures_total {d}
        \\# HELP zigclaw_infer_total Total inference requests
        \\# TYPE zigclaw_infer_total counter
        \\zigclaw_infer_total {d}
        \\# HELP zigclaw_active_connections Current active connections
        \\# TYPE zigclaw_active_connections gauge
        \\zigclaw_active_connections {d}
        \\
        \\# HELP zigclaw_infer_latency_ms Inference latency in milliseconds
        \\# TYPE zigclaw_infer_latency_ms histogram
        \\{s}
        \\zigclaw_infer_latency_ms_sum 0
        \\zigclaw_infer_latency_ms_count {d}
        \\
        \\# HELP zigclaw_uring_accept_total Total accept operations
        \\# TYPE zigclaw_uring_accept_total counter
        \\zigclaw_uring_accept_total {d}
        \\# HELP zigclaw_uring_read_total Total read operations
        \\# TYPE zigclaw_uring_read_total counter
        \\zigclaw_uring_read_total {d}
        \\# HELP zigclaw_uring_write_total Total write operations
        \\# TYPE zigclaw_uring_write_total counter
        \\zigclaw_uring_write_total {d}
        \\
        \\# HELP zigclaw_uring_sq_ring_used SQ ring entries used
        \\# TYPE zigclaw_uring_sq_ring_used gauge
        \\zigclaw_uring_sq_ring_used {d}
        \\# HELP zigclaw_uring_cq_ring_used CQ ring entries used
        \\# TYPE zigclaw_uring_cq_ring_used gauge
        \\zigclaw_uring_cq_ring_used {d}
        \\
    , .{ http, auth, infer, active, bucket_lines[0..bucket_len], infer, accept_total, read_total, write_total, sq_used, cq_used }) catch unreachable;

    return result.len;
}
