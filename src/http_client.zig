// src/http_client.zig
// ZigClaw V2.4 Phase15 | OpenRouter HTTP 客户端 | TLS 降维风格
const std = @import("std");
const io_uring = @import("io_uring.zig");
const tls_client = @import("tls_client.zig"); // 新增 TLS 客户端

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

/// 同步 HTTP POST 请求，支持 TCP 和 TLS（当 port=443 时自动使用 TLS）
/// 签名：post(host, port, path, body, api_key)
pub fn post(host: []const u8, port: u16, path: []const u8, body: []const u8, api_key: []const u8) !HttpResponse {
    // 构造 HTTP 请求（与传输无关）
    var req_buf: [4096]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf,
        "POST {s} HTTP/1.1\\r\\nHost: {s}\\r\\nContent-Type: application/json\\r\\nAuthorization: Bearer {s}\\r\\nContent-Length: {d}\\r\\nConnection: close\\r\\n\\r\\n{s}",
        .{ path, host, api_key, body.len, body });

    if (port == 443) {
        // TLS 路径（OpenRouter 标准端口）
        var tls_conn = try tls_client.TlsConnection.init(host, port);
        defer tls_conn.close();

        // 发送请求
        _ = try tls_conn.send(req_buf[0..req.len]);

        // 接收响应
        var resp = HttpResponse{ .status_code = 0, .body_buf = [_]u8{0} ** 8192, .body_len = 0 };
        const recv_len = try tls_conn.recv(&resp.body_buf);
        resp.body_len = @intCast(recv_len);

        // 解析状态码（HTTP 响应第一行：HTTP/1.1 200 OK）
        if (resp.body_len >= 12 and std.mem.startsWith(u8, resp.body_buf[0..resp.body_len], "HTTP/1.1 ")) {
            const status_slice = resp.body_buf[9..12];
            resp.status_code = try std.fmt.parseInt(u32, status_slice, 10);
        }

        return resp;
    } else {
        // 原始 TCP 路径（保留用于其他端口，但项目目前仅用 443）
        // 1. 创建 socket
        const sockfd_i32: i32 = try io_uring.Syscall.socket(io_uring.AF_INET, io_uring.SOCK_STREAM, 0);
        if (sockfd_i32 < 0) return error.SocketFailed;
        const sockfd: u32 = @intCast(sockfd_i32);
        defer io_uring.Syscall.close(sockfd);

        // 2. DNS 解析 — openrouter.ai 真实 IP：104.18.3.115
        const ip_bytes = [4]u8{ 104, 18, 3, 115 }; // 104.18.3.115
        const ip_network_order = std.mem.readInt(u32, &ip_bytes, .big);

        var addr = io_uring.SockAddrIn{
            .family = io_uring.AF_INET,
            .port = io_uring.htons(port),
            .addr = ip_network_order,
        };
        try io_uring.Syscall.connect(sockfd, &addr, @sizeOf(io_uring.SockAddrIn));

        // 3. 构造 HTTP 请求（已在上面构造好 req_buf 和 req）
        // 4. 发送请求
        _ = try io_uring.Syscall.send(sockfd, &req_buf, req.len, 0);

        // 5. 接收响应
        var resp = HttpResponse{ .status_code = 0, .body_buf = [_]u8{0} ** 8192, .body_len = 0 };
        const recv_len_i32: i32 = try io_uring.Syscall.recv(sockfd, &resp.body_buf, 8192, 0);
        const recv_len: usize = @intCast(recv_len_i32);
        resp.body_len = @intCast(recv_len);

        // 6. 解析状态码（HTTP 响应第一行：HTTP/1.1 200 OK）
        if (resp.body_len >= 12 and std.mem.startsWith(u8, resp.body_buf[0..resp.body_len], "HTTP/1.1 ")) {
            const status_slice = resp.body_buf[9..12];
            resp.status_code = try std.fmt.parseInt(u32, status_slice, 10);
        }

        return resp;
    }
}