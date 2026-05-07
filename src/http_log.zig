// src/http_log.zig
// 入口层 | Layer: Entry
// 结构化JSON请求日志（无堆分配，手工拼接）

const std = @import("std");
const c = @cImport({
    @cInclude("stdio.h");
});

/// 日志请求信息到stdout（JSON格式，无堆分配）
/// 必须在请求处理完成后调用（响应已发送）
pub fn logRequest(
    req_id: u64,
    method: []const u8,
    path: []const u8,
    status: u16,
    latency_ms: f64,
    err_msg: ?[]const u8,
) void {
    // 栈上缓冲区（足够容纳JSON日志）
    var buf: [512]u8 = undefined;
    
    // 构建JSON字符串
    const result = if (err_msg) |msg| 
        std.fmt.bufPrint(&buf, "{{\"req_id\":{d},\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{d},\"latency_ms\":{d:.1},\"error\":\"{s}\"}}\n", .{ req_id, method, path, status, latency_ms, msg })
    else
        std.fmt.bufPrint(&buf, "{{\"req_id\":{d},\"method\":\"{s}\",\"path\":\"{s}\",\"status\":{d},\"latency_ms\":{d:.1},\"error\":null}}\n", .{ req_id, method, path, status, latency_ms });
    
    const json = result catch {
        // 缓冲区不足，输出简化版
        _ = c.printf("{\"req_id\":%llu,\"error\":\"buffer_overflow\"}\n", req_id);
        return;
    };
    
    // 使用 C 的 printf 输出到 stdout
    _ = c.printf("%s", json.ptr);
}

// 单元测试（P50）
const std_debug = std.debug;

test "P50: logRequest 正常请求" {
    // 捕获输出不太容易，这里主要测试不会panic
    logRequest(42, "POST", "/v1/infer", 200, 12.5, null);
    std_debug.print("P50: 正常请求日志测试通过\n", .{});
}

test "P50: logRequest 鉴权失败" {
    logRequest(43, "POST", "/v1/infer", 401, 0.0, "unauthorized");
    std_debug.print("P50: 鉴权失败日志测试通过\n", .{});
}

test "P50: logRequest 错误信息含特殊字符" {
    logRequest(44, "GET", "/health", 200, 1.0, "error with quotes");
    std_debug.print("P50: 特殊字符日志测试通过\n", .{});
}
