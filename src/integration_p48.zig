// src/integration_p48.zig
// DRD-048：P0 收官 — P48 集成测试
// 验证：原子递增精度、鉴权失败指标、Prometheus 格式输出

const std = @import("std");
const debug = std.debug;
const mem = std.mem;

// 导入 P48 模块
const metrics_mod = @import("metrics.zig");

// 集成测试1：原子递增精度
test "P48 Integration: 原子递增精度" {
    // 重置计数器（通过读取当前值，然后验证递增）
    const before = metrics_mod.http_requests_total.load(.acquire);
    
    // 连续递增 3 次
    metrics_mod.incrHttpRequests();
    metrics_mod.incrHttpRequests();
    metrics_mod.incrHttpRequests();
    
    const after = metrics_mod.http_requests_total.load(.acquire);
    debug.assert(after == before + 3);
    
    debug.print("P48集成测试：原子递增精度通过 (before={d}, after={d})\n", .{ before, after });
}

// 集成测试2：鉴权失败指标
test "P48 Integration: 鉴权失败指标" {
    const before = metrics_mod.auth_failures_total.load(.acquire);
    
    // 模拟鉴权失败
    metrics_mod.incrAuthFailures();
    metrics_mod.incrAuthFailures();
    
    const after = metrics_mod.auth_failures_total.load(.acquire);
    debug.assert(after == before + 2);
    
    debug.print("P48集成测试：鉴权失败指标通过 (before={d}, after={d})\n", .{ before, after });
}

// 集成测试3：Prometheus 格式输出
test "P48 Integration: Prometheus 格式输出" {
    var buf: [512]u8 = undefined;
    const len = metrics_mod.formatMetrics(&buf);
    
    // 验证长度合理
    debug.assert(len > 0);
    
    // 验证包含 # HELP 和 # TYPE 行
    const output = buf[0..len];
    debug.assert(mem.indexOf(u8, output, "# HELP") != null);
    debug.assert(mem.indexOf(u8, output, "# TYPE") != null);
    
    // 验证包含指标名称
    debug.assert(mem.indexOf(u8, output, "zigclaw_http_requests_total") != null);
    debug.assert(mem.indexOf(u8, output, "zigclaw_auth_failures_total") != null);
    debug.assert(mem.indexOf(u8, output, "zigclaw_infer_total") != null);
    debug.assert(mem.indexOf(u8, output, "zigclaw_active_connections") != null);
    
    debug.print("P48集成测试：Prometheus 格式输出通过 (len={d})\n", .{len});
    debug.print("输出预览：\n{s}\n", .{output});
}
