// src/http_server.zig
// ZigClaw V2.4 | C阶段 | HTTP 服务化 | 最小可用
const std = @import("std");
const io_uring = @import("io_uring.zig");
const router = @import("router.zig");
const orchestrator = @import("orchestrator.zig");
const token = @import("token.zig");
const quantizer = @import("quantizer.zig");

// HTTP 响应模板（JSON）
const RESPONSE_TEMPLATE =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: application/json\r\n" ++
    "Content-Length: {d}\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "{{\"status\": \"ok\", \"result\": \"{s}\"}}\n";

pub const HttpServer = struct {
    ring: io_uring.Ring,
    listen_fd: i32,
    port: u16,

    /// 初始化 HTTP 服务器：socket → bind → listen
    pub fn init() !HttpServer {
        var ring = try io_uring.Ring.init();
        errdefer io_uring.Syscall.close(ring.fd);

        const listen_fd = try io_uring.Syscall.socket(
            io_uring.AF_INET,
            io_uring.SOCK_STREAM,
            0,
        );
        errdefer io_uring.Syscall.close(@intCast(listen_fd));

        // 绑定 0.0.0.0:8080
        var addr = io_uring.SockAddrIn{
            .family = io_uring.AF_INET,
            .port = io_uring.htons(8080),
            .addr = 0, // 0.0.0.0
        };
        try io_uring.Syscall.bind(listen_fd, &addr, @sizeOf(io_uring.SockAddrIn));
        try io_uring.Syscall.listen(listen_fd, 128);

        // 获取实际端口（如果是 0 让内核分配）
        var actual_addr: io_uring.SockAddrIn = undefined;
        var addr_len: u32 = @sizeOf(io_uring.SockAddrIn);
        try io_uring.Syscall.getsockname(listen_fd, &actual_addr, &addr_len);
        const port = io_uring.htons(actual_addr.port);

        std.debug.print("🌐 HTTP 服务器启动: http://127.0.0.1:{d}/\n", .{port});

        // 取消 errdefer，因为我们要返回这些 fd
        return HttpServer{
            .ring = ring,
            .listen_fd = listen_fd,
            .port = port,
        };
    }

    /// 运行服务器主循环（单连接示例，后续扩展为多连接）
    pub fn run(self: *HttpServer) !void {
        std.debug.print("等待连接...\n", .{});

        // 简化版：单次 accept + 处理
        const conn_fd = try io_uring.Syscall.accept(self.listen_fd, null, null);
        defer io_uring.Syscall.close(conn_fd);

        std.debug.print("收到连接，fd={d}\n", .{conn_fd});

        // 读取 HTTP 请求（简化：读取 4096 字节）
        var buf: [4096]u8 = undefined;
        const nread = try io_uring.Syscall.recv(conn_fd, &buf, buf.len, 0);
        if (nread <= 0) {
            std.debug.print("读取请求失败\n", .{});
            return;
        }

        const request = buf[0..@intCast(usize, nread)];
        std.debug.print("收到请求:\n{s}\n", .{request});

        // 解析 HTTP 路径（简化：提取 /infer?input=xxx）
        const path = extract_path(request);
        std.debug.print("请求路径: {s}\n", .{path});

        // 调用推理引擎（示例：直接返回模拟结果）
        const result = "模拟推理结果：ZigClaw HTTP 服务化成功";
        const response_body = result;

        // 构造 HTTP 响应
        const header_part = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ";
        const len_str = std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{response_body.len}) catch unreachable;
        defer std.heap.page_allocator.free(len_str);

        const response = std.fmt.allocPrint(std.heap.page_allocator,
            "{s}{s}\r\nConnection: close\r\n\r\n{s}",
            .{ header_part, len_str, response_body }
        ) catch unreachable;
        defer std.heap.page_allocator.free(response);

        // 发送响应
        _ = try io_uring.Syscall.send(conn_fd, response.ptr, response.len, 0);
        std.debug.print("响应已发送，长度={d}\n", .{response.len});
    }

    /// 释放服务器资源
    pub fn deinit(self: *HttpServer) void {
        io_uring.Syscall.close(self.listen_fd);
        self.ring.deinit();
    }
};

/// 从 HTTP 请求中提取路径（简化版）
fn extract_path(request: []const u8) []const u8 {
    // 查找 "GET /path HTTP/1.1" 中的路径
    const end_line = std.mem.indexOf(u8, request, "\r\n") orelse request.len;
    const first_line = request[0..end_line];
    var iter = std.mem.split(u8, first_line, " ");
    const method = iter.next() orelse return "/";
    const path = iter.next() orelse return "/";
    return path;
}
