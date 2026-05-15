// src/entry/middleware.zig
// 入口层 | Layer: Entry
// Bearer Token 鉴权中间件 — 零堆分配，直接比较常量字符串

const std = @import("std");
const debug = std.debug;
const fmt = std.fmt;
const mem = std.mem;
const io_uring = @import("../io_uring.zig");

/// 从环境变量读取鉴权 Token（零依赖，零硬编码）
/// 环境变量：ZIGCLAW_AUTH_TOKEN
/// 未设置时返回 null，鉴权失败
/// 使用 openat + read 读取 /proc/self/environ（Zig 0.16 无 std.os.getenv）
fn getAuthToken() ?[]const u8 {
    const fd = io_uring.Syscall.openat(
        @as(i32, -100),
        "/proc/self/environ",
        io_uring.Syscall.O_RDONLY,
        0,
    ) catch return null;
    defer io_uring.Syscall.close(@intCast(fd));

    var buf: [4096]u8 = undefined;
    const n = io_uring.read(fd, &buf, buf.len) catch return null;
    if (n == 0) return null;

    // 在 environ 中搜索 ZIGCLAW_AUTH_TOKEN=
    const needle = "ZIGCLAW_AUTH_TOKEN=";
    const env_buf = buf[0..n];
    var pos: usize = 0;
    while (pos + needle.len < env_buf.len) {
        if (mem.eql(u8, env_buf[pos..pos+needle.len], needle)) {
            const val_start = pos + needle.len;
            // 环境变量以 null 分隔
            var val_end = val_start;
            while (val_end < env_buf.len and env_buf[val_end] != 0) {
                val_end += 1;
            }
            if (val_end > val_start) {
                return env_buf[val_start..val_end];
            }
        }
        // 跳到下一个 null 分隔的条目
        while (pos < env_buf.len and env_buf[pos] != 0) {
            pos += 1;
        }
        pos += 1; // 跳过 null
    }
    return null;
}

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
    const expected = getAuthToken() orelse return .{ .allowed = false, .tenant_id = 0 };
    const allowed = mem.eql(u8, token, expected);
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
    // 注意：checkAuth 现在从环境变量 ZIGCLAW_AUTH_TOKEN 读取
    // 此测试验证 extractBearerToken 解析逻辑
    const headers = 
        "GET /v1/infer HTTP/1.1\r\n" ++
        "Authorization: Bearer test-token\r\n" ++
        "Content-Type: application/json\r\n";
    const token = extractBearerToken(headers);
    debug.assert(token != null);
    debug.assert(mem.eql(u8, token.?, "test-token"));
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
