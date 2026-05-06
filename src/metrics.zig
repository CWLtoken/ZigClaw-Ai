// src/metrics.zig
// 观测层 | Layer: Observability
// 无锁原子指标收集，用于 Prometheus 格式导出

const std = @import("std");

// 核心指标（静态原子变量）
pub var http_requests_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var auth_failures_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var infer_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var active_connections: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

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
// 调用方提供缓冲区（建议 512 字节以上）
pub fn formatMetrics(buf: []u8) usize {
    const http = http_requests_total.load(.acquire);
    const auth = auth_failures_total.load(.acquire);
    const infer = infer_total.load(.acquire);
    const active = active_connections.load(.acquire);

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
    , .{ http, auth, infer, active }) catch |err| {
        _ = err; // 消除未使用警告
        return 0; // 缓冲区不足
    };

    return result.len;
}
