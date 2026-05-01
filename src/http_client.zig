// src/http_client.zig
// ZigClaw V2.4 Phase14 | OpenRouter HTTP 客户端 | 降维风格
const std = @import("std");
const io_uring = @import("io_uring.zig");

pub const HttpRequest = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    body: []const u8,
    content_type: []const u8 = "application/json",
};

pub const HttpResponse = struct {
    status_code: u32,
    body_buf: [8192]u8,
    body_len: u32,
};

/// 同步 HTTP POST 请求，纯 syscall 降维
/// 签名：post(host, port, path, body, api_key)
pub fn post(host: []const u8, port: u16, path: []const u8, body: []const u8, api_key: []const u8) !HttpResponse {
    // 1. 创建 socket
    const sockfd_i32: i32 = try io_uring.Syscall.socket(io_uring.AF_INET, io_uring.SOCK_STREAM, 0);
    if (sockfd_i32 < 0) return error.SocketFailed;
    const sockfd: u32 = @intCast(sockfd_i32);
    defer io_uring.Syscall.close(sockfd);

    // 2. DNS 解析 — openrouter.ai 真实 IP：104.18.3.115
    //    用 std.mem.readInt 解析四个字节转为网络字节序 u32
    const ip_bytes = [4]u8{ 104, 18, 3, 115 }; // 104.18.3.115
    const ip_network_order = std.mem.readInt(u32, &ip_bytes, .big);

    var addr = io_uring.SockAddrIn{
        .family = io_uring.AF_INET,
        .port = io_uring.htons(port),
        .addr = ip_network_order,
    };
    try io_uring.Syscall.connect(sockfd, &addr, @sizeOf(io_uring.SockAddrIn));

    // 3. 构造 HTTP 请求
    var req_buf: [4096]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf,
        "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Type: application/json\r\nAuthorization: Bearer {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ path, host, api_key, body.len, body });

    // 4. 发送请求
    _ = try io_uring.Syscall.send(sockfd, &req_buf, req.len, 0);

    // 5. 接收响应
    var resp = HttpResponse{ .status_code = 0, .body_buf = [_]u8{0} ** 8192, .body_len = 0 };
    const recv_len_i32: i32 = try io_uring.Syscall.recv(sockfd, &resp.body_buf, 8192, 0);
    const recv_len: usize = @intCast(recv_len_i32);
    resp.body_len = @intCast(recv_len);

    // 6. 解析状态码（HTTP 响应第一行：HTTP/1.1 200 OK）
    if (recv_len >= 12 and std.mem.startsWith(u8, resp.body_buf[0..recv_len], "HTTP/1.1 ")) {
        const status_slice = resp.body_buf[9..12];
        resp.status_code = try std.fmt.parseInt(u32, status_slice, 10);
    }

    return resp;
}
