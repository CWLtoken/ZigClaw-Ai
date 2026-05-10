// src/entry/middleware.zig
// 入口层 | Layer: Entry
// Bearer Token 鉴权中间件 — 零堆分配，直接比较常量字符串

const debug = @import("std").debug;
const fmt = @import("std").fmt;
const mem = @import("std").mem;

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

/// 鉴权结果（v6.1.0 扩展）
pub const AuthResult = struct {
    allowed: bool,
    tenant_id: u64,   // 从 X-Tenant-ID 头部提取，不存在则默认 0
};

/// 检查请求鉴权是否通过（v6.1.0 扩展版本）
pub fn checkAuthWithTenant(headers: []const u8) AuthResult {
    const token = extractBearerToken(headers) orelse return .{ .allowed = false, .tenant_id = 0 };
    const allowed = mem.eql(u8, token, VALID_TOKEN);
    // 提取 X-Tenant-ID
    var tenant_id: u64 = 0;
    if (extractHeader(headers, "X-Tenant-ID")) |tid_str| {
        tenant_id = fmt.parseInt(u64, tid_str, 10) catch 0;
    }
    return .{ .allowed = allowed, .tenant_id = tenant_id };
}

/// 检查请求鉴权是否通过（兼容旧接口）
pub fn checkAuth(headers: ?[]const u8) bool {
    const h = headers orelse return false;
    return checkAuthWithTenant(h).allowed;
}

/// 从 HTTP 头部中提取指定字段值（零拷贝）
fn extractHeader(headers: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    const name_len = name.len;
    while (i + name_len <= headers.len) {
        if (mem.eql(u8, headers[i..i+name_len], name)) {
            var pos = i + name_len;
            // 跳过 ":"
            while (pos < headers.len and headers[pos] != ':') {
                pos += 1;
            }
            if (pos < headers.len) pos += 1;  // 跳过 ':'
            // 跳过空白
            while (pos < headers.len and (headers[pos] == ' ' or headers[pos] == '\t')) {
                pos += 1;
            }
            var end: usize = pos;
            while (end < headers.len and headers[end] != '\r' and headers[end] != '\n') {
                end += 1;
            }
            if (end > pos) {
                return headers[pos..end];
            }
        }
        i += 1;
    }
    return null;
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
