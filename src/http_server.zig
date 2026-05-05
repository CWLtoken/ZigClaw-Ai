// src/http_server.zig
// ZigClaw V2.4 | C阶段 | HTTP 服务化 | 增强版：路由 + Orchestrator 对接
const std = @import("std");
const io_uring = @import("io_uring.zig");
const orchestrator = @import("orchestrator.zig");
const token = @import("token.zig");
const quantizer = @import("quantizer.zig");
const mem = std.mem;
const Arena = std.heap.ArenaAllocator;

// HTTP 请求结构
const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    query: ?[]const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,

    fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
    }
};

// HTTP 响应结构
const HttpResponse = struct {
    status_code: u16,
    status_text: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,

    fn init() HttpResponse {
        return HttpResponse{
            .status_code = 200,
            .status_text = "OK",
            .headers = std.StringHashMap([]const u8).init(std.heap.page_allocator),
            .body = "",
        };
    }

    fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
    }
};

pub const HttpServer = struct {
    ring: io_uring.Ring,
    listen_fd: i32,
    port: u16,

    /// 初始化 HTTP 服务器
    pub fn init() !HttpServer {
        var ring = try io_uring.Ring.init();
        errdefer ring.deinit(); // 只在失败时释放

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

        // 获取实际端口
        var actual_addr: io_uring.SockAddrIn = undefined;
        var addr_len: u32 = @sizeOf(io_uring.SockAddrIn);
        try io_uring.Syscall.getsockname(listen_fd, &actual_addr, &addr_len);
        const port = io_uring.htons(actual_addr.port);

        std.debug.print("🌐 HTTP 服务器启动: http://127.0.0.1:{d}/\n", .{port});
        std.debug.print("   路由：\n", .{});
        std.debug.print("     GET /health → 健康检查\n", .{});
        std.debug.print("     GET /infer?input=xxx&modality=text|image → 推理\n", .{});

        // 取消 errdefer，因为要返回这些资源
        return HttpServer{
            .ring = ring,
            .listen_fd = listen_fd,
            .port = port,
        };
    }

    /// 运行服务器主循环（简化版：单连接处理）
    pub fn run(self: *HttpServer) !void {
        while (true) {
            std.debug.print("等待连接...\n", .{});

            const conn_fd = try io_uring.Syscall.accept(self.listen_fd, null, null);
            defer io_uring.Syscall.close(conn_fd);

            std.debug.print("收到连接，fd={d}\n", .{conn_fd});

            // 读取 HTTP 请求
            var buf: [8192]u8 = undefined;
            const nread = try io_uring.Syscall.recv(conn_fd, &buf, buf.len, 0);
            if (nread <= 0) {
                std.debug.print("读取请求失败\n", .{});
                continue;
            }

            const request_bytes = buf[0..@intCast(usize, nread)];
            
            // 解析 HTTP 请求
            var arena = Arena.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            const req = parseHttpRequest(alloc, request_bytes) catch |err| {
                std.debug.print("解析请求失败: {}\n", .{err});
                sendErrorResponse(conn_fd, 400, "Bad Request") catch {};
                continue;
            };
            defer req.deinit();

            std.debug.print("请求: {s} {s}\n", .{req.method, req.path});

            // 路由处理
            if (mem.eql(u8, req.path, "/health")) {
                handleHealth(conn_fd) catch |err| {
                    std.debug.print("处理 /health 失败: {}\n", .{err});
                };
            } else if (mem.startsWith(u8, req.path, "/infer")) {
                handleInfer(conn_fd, &req) catch |err| {
                    std.debug.print("处理 /infer 失败: {}\n", .{err});
                };
            } else {
                sendErrorResponse(conn_fd, 404, "Not Found") catch {};
            }
        }
    }

    /// 释放服务器资源
    pub fn deinit(self: *HttpServer) void {
        io_uring.Syscall.close(self.listen_fd);
        self.ring.deinit();
    }
};

/// 解析 HTTP 请求
fn parseHttpRequest(alloc: std.mem.Allocator, raw: []const u8) !HttpRequest {
    var headers = std.StringHashMap([]const u8).init(alloc);

    // 解析请求行
    const first_line_end = mem.indexOf(u8, raw, "\r\n") orelse return error.InvalidRequest;
    const first_line = raw[0..first_line_end];

    var iter = mem.split(u8, first_line, " ");
    const method = iter.next() orelse return error.InvalidRequest;
    const full_path = iter.next() orelse return error.InvalidRequest;
    _ = iter.next(); // 跳过 HTTP/1.1

    // 分离路径和查询参数
    var path = full_path;
    var query: ?[]const u8 = null;
    if (mem.indexOf(u8, full_path, "?")) |pos| {
        path = full_path[0..pos];
        query = full_path[pos+1..];
    }

    // 解析 headers（简化版）
    var body_start: usize = first_line_end + 2;
    while (body_start < raw.len) {
        const line_end = mem.indexOf(u8, raw[body_start..], "\r\n") orelse break;
        const line = raw[body_start..body_start + line_end];
        if (line.len == 0) {
            body_start += 2; // 跳过分隔空行
            break;
        }

        if (mem.indexOf(u8, line, ":")) |colon_pos| {
            const key = mem.trim(u8, line[0..colon_pos], " ");
            const value = mem.trim(u8, line[colon_pos+1..], " ");
            try headers.put(key, value);
        }
        body_start += line_end + 2;
    }

    // 提取 body
    const body = if (body_start < raw.len) raw[body_start..] else "";

    return HttpRequest{
        .method = method,
        .path = path,
        .query = query,
        .headers = headers,
        .body = body,
    };
}

/// 处理 /health 健康检查
fn handleHealth(conn_fd: i32) !void {
    const body = "{\"status\":\"ok\",\"service\":\"zigclaw-http\"}";
    const response = try std.fmt.allocPrint(std.heap.page_allocator,
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n{s}",
        .{body.len, body}
    );
    defer std.heap.page_allocator.free(response);

    _ = try io_uring.Syscall.send(conn_fd, response.ptr, response.len, 0);
    std.debug.print("已发送 /health 响应\n", .{});
}

/// 处理 /infer 推理请求
fn handleInfer(conn_fd: i32, req: *const HttpRequest) !void {
    // 解析查询参数：input 和 modality
    const query = req.query orelse {
        sendErrorResponse(conn_fd, 400, "Missing query parameters") catch {};
        return;
    };

    var input: ?[]const u8 = null;
    var modality: []const u8 = "text"; // 默认文本

    var params = mem.split(u8, query, "&");
    while (params.next()) |param| {
        if (mem.startsWith(u8, param, "input=")) {
            input = param[6..]; // 跳过 "input="
        } else if (mem.startsWith(u8, param, "modality=")) {
            modality = param[9..]; // 跳过 "modality="
        }
    }

    if (input == null) {
        sendErrorResponse(conn_fd, 400, "Missing 'input' parameter") catch {};
        return;
    }

    std.debug.print("推理请求: input='{s}', modality='{s}'\n", .{input.?, modality});

    // 调用 Orchestrator 进行推理（简化：直接返回模拟结果）
    // TODO: 真实对接 orchestrator.infer(...)
    const result = try std.fmt.allocPrint(std.heap.page_allocator,
        "{{\"input\":\"{s}\",\"modality\":\"{s}\",\"result\":\"zigclaw-infer-ok\"}}",
        .{input.?, modality}
    );
    defer std.heap.page_allocator.free(result);

    const response_body = result;
    const response = try std.fmt.allocPrint(std.heap.page_allocator,
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n{s}",
        .{response_body.len, response_body}
    );
    defer std.heap.page_allocator.free(response);

    _ = try io_uring.Syscall.send(conn_fd, response.ptr, response.len, 0);
    std.debug.print("已发送 /infer 响应\n", .{});
}

/// 发送错误响应
fn sendErrorResponse(conn_fd: i32, status_code: u16, message: []const u8) !void {
    const response = try std.fmt.allocPrint(std.heap.page_allocator,
        "HTTP/1.1 {d} {s}\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n{s}",
        .{status_code, message, message.len, message}
    );
    defer std.heap.page_allocator.free(response);

    _ = try io_uring.Syscall.send(conn_fd, response.ptr, response.len, 0);
}
