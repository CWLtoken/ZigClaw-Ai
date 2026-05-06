// src/http_server.zig
// ZigClaw V2.4 | 阶段23C | 故障恢复与可观测性
const std = @import("std");
const io_uring = @import("io_uring.zig");
const mem = std.mem;
const time = std.time;
const context = @import("context.zig");
const middleware = @import("entry/middleware.zig");
const metrics_mod = @import("metrics.zig");

// 服务器指标（原子操作保证线程安全）
pub const ServerMetrics = struct {
    uptime_start: i64,           // 启动时间戳（毫秒）— 简化版：暂时为0
    total_requests: std.atomic.Value(u64),
    active_connections: std.atomic.Value(u32),
    error_count: std.atomic.Value(u64),
    
    pub fn init() ServerMetrics {
        return ServerMetrics{
            .uptime_start = 0, // 简化：暂时不使用真实时间戳
            .total_requests = std.atomic.Value(u64).init(0),
            .active_connections = std.atomic.Value(u32).init(0),
            .error_count = std.atomic.Value(u64).init(0),
        };
    }
    
    pub fn inc_requests(self: *ServerMetrics) void {
        _ = self.total_requests.rmw(.Add, 1, .acquire);
    }
    
    pub fn inc_connections(self: *ServerMetrics) void {
        _ = self.active_connections.rmw(.Add, 1, .acquire);
    }
    
    pub fn dec_connections(self: *ServerMetrics) void {
        _ = self.active_connections.rmw(.Sub, 1, .acquire);
    }
    
    pub fn inc_errors(self: *ServerMetrics) void {
        _ = self.error_count.rmw(.Add, 1, .acquire);
    }
    
    pub fn get_uptime_ms(self: *const ServerMetrics) i64 {
        _ = self; // 消除未使用警告
        return 0; // 简化：暂时返回0，真实实现需要正确的时间戳获取
    }
    
    pub fn get_total_requests(self: *const ServerMetrics) u64 {
        return self.total_requests.load(.acquire);
    }
    
    pub fn get_active_connections(self: *const ServerMetrics) u32 {
        return self.active_connections.load(.acquire);
    }
    
    pub fn get_error_count(self: *const ServerMetrics) u64 {
        return self.error_count.load(.acquire);
    }
};

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
    metrics: *ServerMetrics,  // 服务器指标
    running: std.atomic.Value(bool),  // 优雅关闭标志

    /// 初始化 HTTP 服务器
    pub fn init(metrics: *ServerMetrics) !HttpServer {
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
        std.debug.print("     GET /health?verbose=true → 详细指标\n", .{});
        std.debug.print("     GET /infer?input=xxx&modality=text|image → 推理\n", .{});

        // 取消 errdefer，因为要返回这些资源
        return HttpServer{
            .ring = ring,
            .listen_fd = listen_fd,
            .port = port,
            .metrics = metrics,
            .running = std.atomic.Value(bool).init(true),
        };
    }

    /// 运行服务器主循环（支持优雅关闭）
    pub fn run(self: *HttpServer) !void {
        while (self.is_running()) {
            // 检查是否应该停止接受新连接
            if (!self.is_running()) break;

            std.debug.print("等待连接...\n", .{});

            // 使用 io_uring ACCEPT 获取连接
            const conn_fd = io_uring.Syscall.accept(self.listen_fd, null, null) catch |err| {
                _ = err; // 消除未使用警告
                if (!self.is_running()) break;
                continue;
            };
            // 注意：这里不 defer close，因为连接处理完成后会关闭
            // 更新活跃连接数
            self.metrics.inc_connections();

            std.debug.print("收到连接，fd={d}\n", .{conn_fd});

            // 读取 HTTP 请求
            var buf: [8192]u8 = undefined;
            const nread = io_uring.Syscall.recv(conn_fd, &buf, buf.len, 0) catch |err| {
                std.debug.print("读取请求失败: {}\n", .{err});
                io_uring.Syscall.close(@intCast(conn_fd));
                self.metrics.dec_connections();
                continue;
            };

            if (nread <= 0) {
                io_uring.Syscall.close(@intCast(conn_fd));
                self.metrics.dec_connections();
                continue;
            }

            // 更新请求计数
            self.metrics.inc_requests();

            const request_bytes = buf[0..@intCast(nread)];

            // 解析 HTTP 请求（简化版）
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            var req = parseHttpRequest(alloc, request_bytes) catch |err| {
                std.debug.print("解析请求失败: {}\n", .{err});
                sendErrorResponse(conn_fd, 400, "Bad Request") catch {};
                io_uring.Syscall.close(@intCast(conn_fd));
                self.metrics.dec_connections();
                self.metrics.inc_errors();
                continue;
            };
            defer req.deinit();

        std.debug.print("请求: {s} {s}\n", .{req.method, req.path});

        // 生成请求上下文（原子ID，零分配）
        var ctx = context.RequestContext.init(req.method, req.path);
        std.debug.print("请求ID: {s}\n", .{ctx.getFormattedId()});

        // P48-2: 递增 HTTP 请求总数
        metrics_mod.incrHttpRequests();

        // 路由处理
            if (mem.eql(u8, req.path, "/health")) {
                handleHealth(self.metrics, conn_fd, req.query) catch |err| {
                    std.debug.print("处理 /health 失败: {}\n", .{err});
                };
        } else if (mem.eql(u8, req.path, "/v1/infer") and mem.eql(u8, req.method, "POST")) {
            // P48-2: 递增推理请求计数
            metrics_mod.incrInfer();
            
            // 计算推理延迟（暂时使用固定值 100ms 用于测试直方图）
            const latency_ms: f64 = 100.0;
            
            // POST /v1/infer 处理（鉴权+推理）
            const auth_header = if (req.headers.get("Authorization")) |val| val else null;
            if (!middleware.checkAuth(auth_header)) {
                // P48-2: 递增鉴权失败计数
                metrics_mod.incrAuthFailures();
                sendErrorResponse(conn_fd, 401, "Unauthorized") catch {};
                self.metrics.inc_errors();
            } else {
                // 鉴权成功，暂返回 503（后续接入真实推理）
                sendErrorResponse(conn_fd, 503, "Service Unavailable") catch {};
                self.metrics.inc_errors();
            }
            
            // P49-2: 记录推理延迟到直方图
            metrics_mod.observeInferLatency(latency_ms);
        } else if (mem.eql(u8, req.path, "/metrics")) {
            // P48-3: 返回 Prometheus 格式指标
            var metrics_buf: [512]u8 = undefined;
            const len = metrics_mod.formatMetrics(&metrics_buf);
            const response = std.fmt.allocPrint(std.heap.page_allocator,
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain; version=0.0.4\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n" ++
                "\r\n{s}",
                .{ len, metrics_buf[0..len] }
            ) catch unreachable;
            defer std.heap.page_allocator.free(response);
            _ = io_uring.Syscall.send(conn_fd, response.ptr, response.len, 0) catch |err| {
                std.debug.print("发送/metrics响应失败: {}\n", .{err});
            };
        } else {
                sendErrorResponse(conn_fd, 404, "Not Found") catch {};
                self.metrics.inc_errors();
            }

            // 关闭连接
            io_uring.Syscall.close(@intCast(conn_fd));
            self.metrics.dec_connections();
        }

        std.debug.print("服务器停止接受新连接\n", .{});
    }

    /// 检查服务器是否正在运行
    pub fn is_running(self: *const HttpServer) bool {
        return self.running.load(.acquire);
    }

    /// 请求优雅关闭
    pub fn shutdown(self: *HttpServer) void {
        self.running.store(false, .release);
    }

    /// 释放服务器资源
    pub fn deinit(self: *HttpServer) void {
        io_uring.Syscall.close(@intCast(self.listen_fd));
        self.ring.deinit();
    }
};

/// 解析 HTTP 请求
fn parseHttpRequest(alloc: std.mem.Allocator, raw: []const u8) !HttpRequest {
    var headers = std.StringHashMap([]const u8).init(alloc);

    // 解析请求行
    const first_line_end = mem.indexOf(u8, raw, "\r\n") orelse return error.InvalidRequest;
    const first_line = raw[0..first_line_end];

    var iter = mem.splitSequence(u8, first_line, " ");
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

/// 处理 /health 健康检查（支持 ?verbose=true）
fn handleHealth(metrics: *const ServerMetrics, conn_fd: i32, query: ?[]const u8) !void {
    const verbose = if (query) |q| mem.indexOf(u8, q, "verbose=true") != null else false;

    if (verbose) {
        // 详细模式：返回 JSON 包含 uptime、total_requests、active_connections、error_count
        const uptime_ms = metrics.get_uptime_ms();
        const total_requests = metrics.get_total_requests();
        const active = metrics.get_active_connections();
        const errors = metrics.get_error_count();

        const body = try std.fmt.allocPrint(std.heap.page_allocator,
            "{{\"status\":\"ok\",\"uptime_ms\":{d},\"total_requests\":{d},\"active_connections\":{d},\"error_count\":{d}}}",
            .{ uptime_ms, total_requests, active, errors }
        );
        defer std.heap.page_allocator.free(body);

        const response = try std.fmt.allocPrint(std.heap.page_allocator,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n{s}",
            .{ body.len, body }
        );
        defer std.heap.page_allocator.free(response);

        _ = io_uring.Syscall.send(conn_fd, response.ptr, response.len, 0) catch |err| {
            std.debug.print("发送详细健康响应失败: {}\n", .{err});
            return;
        };
    } else {
        // 简单模式
        const body = "{\"status\":\"ok\",\"service\":\"zigclaw-http\"}";
        const response = try std.fmt.allocPrint(std.heap.page_allocator,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n{s}",
            .{ body.len, body }
        );
        defer std.heap.page_allocator.free(response);

        _ = io_uring.Syscall.send(conn_fd, response.ptr, response.len, 0) catch |err| {
            std.debug.print("发送健康响应失败: {}\n", .{err});
            return;
        };
    }

    std.debug.print("/health 请求处理完成 (verbose={})\n", .{verbose});
}

// 推理功能已移至 http_protocol.zig（阶段23B 封板）
// 当前 /infer 路径在 run() 中直接返回 503 Service Unavailable
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
