// src/entry/middleware.zig
// 入口层 | Layer: Entry
// Bearer Token 鉴权中间件 — 零堆分配，直接比较常量字符串

const std = @import("std");
const mem = std.mem;
const debug = std.debug;

/// 有效 Token 常量（零拷贝引用）
const VALID_TOKEN: []const u8 = "secret-token-123";

/// 从 HTTP 请求头中提取 Bearer Token（零拷贝）
/// 返回 Token 的切片引用，如果不合法返回 null
fn extractBearerToken(headers: []const u8) ?[]const u8 {
    // 搜索 "Authorization:" 头（不区分大小写？简化：精确匹配）
    const prefix = "Authorization:";
    const prefix_len = prefix.len;
    
    var i: usize = 0;
    while (i + prefix_len <= headers.len) {
        if (mem.eql(u8, headers[i..i+prefix_len], prefix)) {
            // 找到头，跳过空白
            var pos = i + prefix_len;
            while (pos < headers.len and (headers[pos] == ' ' or headers[pos] == '\t')) {
                pos += 1;
            }
            // 检查 "Bearer " 前缀
            const bearer = "Bearer ";
            if (pos + bearer.len <= headers.len and 
                mem.eql(u8, headers[pos..pos+bearer.len], bearer)) {
                const token_start = pos + bearer.len;
                // Token 持续到行结束（\r 或 \n）或字符串结束
                var token_end: usize = token_start;
                while (token_end < headers.len and headers[token_end] != '\r' and headers[token_end] != '\n') {
                    token_end += 1;
                }
                if (token_end > token_start) {
                    return headers[token_start..token_end];
                }
            }
            return null; // 格式不对
        }
        i += 1;
    }
    return null;
}

/// 检查请求鉴权是否通过
/// 返回 true 如果合法，false 如果非法或缺失
pub fn checkAuth(headers: []const u8) bool {
    const token = extractBearerToken(headers) orelse return false;
    // 直接比较 Token 字符串（零拷贝）
    return mem.eql(u8, token, VALID_TOKEN);
}

// 单元测试（P47）
test "P47: 鉴权中间件 - 有效 Token" {
    const headers = 
        "GET /v1/infer HTTP/1.1\r\n" ++
        "Authorization: Bearer secret-token-123\r\n" ++
        "Content-Type: application/json\r\n";
    debug.assert(checkAuth(headers) == true);
    debug.print("P47: 有效Token测试通过\n", .{});
}

test "P47: 鉴权中间件 - 缺失 Authorization" {
    const headers = 
        "GET /v1/infer HTTP/1.1\r\n" ++
        "Content-Type: application/json\r\n";
    debug.assert(checkAuth(headers) == false);
    debug.print("P47: 缺失Authorization测试通过\n", .{});
}

test "P47: 鉴权中间件 - 错误 Token" {
    const headers = 
        "GET /v1/infer HTTP/1.1\r\n" ++
        "Authorization: Bearer wrong-token\r\n";
    debug.assert(checkAuth(headers) == false);
    debug.print("P47: 错误Token测试通过\n", .{});
}

test "P47: 鉴权中间件 - 无 Bearer 前缀" {
    const headers = 
        "GET /v1/infer HTTP/1.1\r\n" ++
        "Authorization: Basic abcdef\r\n";
    debug.assert(checkAuth(headers) == false);
    debug.print("P47: 无Bearer前缀测试通过\n", .{});
}
