// src/http_client.zig
// ZigClaw V2.4 Phase14 | 降维 HTTP 客户端 | 泥泞风格
// 依赖：io_uring.zig（Syscall 块），无其他上层依赖
// 禁止：第三方 HTTP 库、JSON 解析库

const std = @import("std");
const io_uring = @import("io_uring.zig");
const mem = std.mem;

/// HTTP 请求
pub const HttpRequest = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    body: []const u8,
    content_type: []const u8 = "application/json",
};

/// HTTP 响应
pub const HttpResponse = struct {
    status_code: u32,
    body_buf: [8192]u8,
    body_len: u32,
    error_occurred: bool = false,
};

/// 发送同步 HTTP POST 请求，返回响应
pub fn post(req: HttpRequest) !HttpResponse {
    // 1. socket() - 返回 i32 (fd)
    const fd_i32 = try io_uring.Syscall.socket(2, 1, 0); // 2 = AF_INET, 1 = SOCK_STREAM
    const fd_u32: u32 = @intCast(fd_i32);
    defer io_uring.Syscall.close(fd_u32);

    // 2. connect() 到目标服务 (127.0.0.1:port)
    // 直接构造 sockaddr_in 结构体（IPv4 地址）
    var addr_buf: [16]u8 align(4) = undefined;
    // sin_family = AF_INET (2)
    mem.writeInt(u16, addr_buf[0..2], 2, .big);
    // sin_port (big endian)
    mem.writeInt(u16, addr_buf[2..4], mem.nativeToBig(u16, req.port), .big);
    // sin_addr = 127.0.0.1 = 0x7F000001 (big endian)
    mem.writeInt(u32, addr_buf[4..8], 0x7F000001, .big);
    // 剩余字节为 0（sin_zero）

    try io_uring.Syscall.connect(fd_i32, @ptrCast(&addr_buf), 16);

    // 3. 构造 HTTP 请求
    var request_buf: [4096]u8 = undefined;
    const request_len = construct_http_request(&request_buf, req);

    // 4. send() HTTP 请求 - send 期望 u32, flags=0
    _ = try io_uring.Syscall.send(fd_u32, &request_buf, request_len, 0);

    // 5. recv() 响应 - recv 期望 i32
    var response = HttpResponse{
        .status_code = 0,
        .body_buf = [_]u8{0} ** 8192,
        .body_len = 0,
    };

    const recv_len = try io_uring.Syscall.recv(fd_i32, &response.body_buf, response.body_buf.len, 0);

    if (recv_len == 0) {
        response.error_occurred = true;
        return response;
    }

    response.body_len = @intCast(recv_len);

    // 6. 解析状态码（简单解析，只取第一行）
    if (parse_status_code(response.body_buf[0..response.body_len])) |code| {
        response.status_code = code;
    } else {
        response.error_occurred = true;
    }

    return response;
}

/// 构造 HTTP POST 请求
fn construct_http_request(buf: *[4096]u8, req: HttpRequest) usize {
    var len: usize = 0;

    // 请求行
    const line1 = std.fmt.bufPrint(buf[len..], "POST {s} HTTP/1.1\r\n", .{req.path}) catch unreachable;
    len += line1.len;

    // Host 头
    const line2 = std.fmt.bufPrint(buf[len..], "Host: {s}:{d}\r\n", .{ req.host, req.port }) catch unreachable;
    len += line2.len;

    // Content-Type
    const line3 = std.fmt.bufPrint(buf[len..], "Content-Type: {s}\r\n", .{req.content_type}) catch unreachable;
    len += line3.len;

    // Content-Length
    const line4 = std.fmt.bufPrint(buf[len..], "Content-Length: {d}\r\n", .{req.body.len}) catch unreachable;
    len += line4.len;

    // 空行
    const line5 = std.fmt.bufPrint(buf[len..], "\r\n", .{}) catch unreachable;
    len += line5.len;

    // Body
    @memcpy(buf[len..][0..req.body.len], req.body);
    len += req.body.len;

    return len;
}

/// 解析 HTTP 状态码（从响应第一行 "HTTP/1.1 200 OK"）
fn parse_status_code(response: []const u8) ?u32 {
    // 找到第一行
    const first_line_end = mem.indexOf(u8, response, "\r\n") orelse return null;
    const first_line = response[0..first_line_end];

    // 分割 "HTTP/1.1 200 OK"
    var parts = mem.splitSequence(u8, first_line, " ");
    _ = parts.first(); // "HTTP/1.1"

    const status_str = parts.next() orelse return null;
    return std.fmt.parseInt(u32, status_str, 10) catch null;
}
