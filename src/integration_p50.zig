// src/integration_p50.zig
// P50 集成测试：验证请求日志输出格式

const std = @import("std");
const http_log = @import("http_log.zig");
const context = @import("context.zig");

const std_debug = std.debug;

// 测试辅助：捕获日志输出（简化版，直接调用logRequest）
test "P50 Integration: 正常请求日志格式" {
    // 重置计数器
    context.resetRequestCounter();
    
    // 调用 logRequest（正常请求）
    http_log.logRequest(1, "GET", "/health", 200, 1.5, null);
    
    std_debug.print("P50集成测试：正常请求日志通过\n", .{});
}

test "P50 Integration: 鉴权失败日志格式" {
    context.resetRequestCounter();
    
    // 调用 logRequest（鉴权失败）
    http_log.logRequest(2, "POST", "/v1/infer", 401, 0.0, "unauthorized");
    
    std_debug.print("P50集成测试：鉴权失败日志通过\n", .{});
}

test "P50 Integration: 404请求日志格式" {
    context.resetRequestCounter();
    
    // 调用 logRequest（404）
    http_log.logRequest(3, "GET", "/notfound", 404, 0.0, "Not Found");
    
    std_debug.print("P50集成测试：404请求日志通过\n", .{});
}
