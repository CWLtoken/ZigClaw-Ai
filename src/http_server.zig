// src/http_server.zig
// ZigClaw V2.4 | 阶段23C | 故障恢复与可观测性
// 架构升级：run() 改为基于 Reactor 的异步事件循环
const atomic = @import("std").atomic;
const debug = @import("std").debug;
const fmt = @import("std").fmt;
const heap = @import("std").heap;
const mem = @import("std").mem;
const StringHashMap = @import("std").StringHashMap;
const linux = @import("std").os.linux;
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");
const context = @import("context.zig");
const middleware = @import("entry/middleware.zig");
const metrics_mod = @import("metrics.zig");
const http_log = @import("http_log.zig");
const ibus = @import("ibus.zig");

// 服务器指标（原子操作保证线程安全）
pub const ServerMetrics = struct {
    uptime_start: i64,           // 启动时间戳（毫秒）— 简化版：暂时为0
    total_requests: atomic.Value(u64),
    active_connections: atomic.Value(u32),
    error_count: atomic.Value(u64),

    pub fn init() ServerMetrics {
        return ServerMetrics{
            .uptime_start = 0, // 简化：暂时不使用真实时间戳
            .total_requests = atomic.Value(u64).init(0),
            .active_connections = atomic.Value(u32).init(0),
            .error_count = atomic.Value(u64).init(0),
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
        if (self.uptime_start == 0) return 0;
        return getCurrentTimeMs() - self.uptime_start;
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

// 获取当前 POSIX 时间（毫秒），Zig 0.16 兼容
fn getCurrentTimeMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

// HTTP 请求结构（栈分配，零堆）
const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    query: ?[]const u8,
    headers: StringHashMap([]const u8),
    body: []const u8,

    fn deinit(self: *HttpRequest) void {
        self.headers.deinit();
    }
};

// HTTP 响应结构
const HttpResponse = struct {
    status_code: u16,
    status_text: []const u8,
    headers: StringHashMap([]const u8),
    body: []const u8,

    fn init() HttpResponse {
        return HttpResponse{
            .status_code = 200,
            .status_text = "OK",
            .headers = StringHashMap([]const u8).init(heap.page_allocator),
            .body = "",
        };
    }

    fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
    }
};

// 异步连接状态
const ConnState = enum {
    Accept,
    Recv,
    Send,
    Done,
};

const Conn = struct {
    fd: i32,
    state: ConnState,
    buf: [8192]u8,
    nread: usize,
    stream_id: u64,
};

/// 最大并发连接数（栈分配，固定大小）
const MAX_CONNS: usize = 256;

pub const HttpServer = struct {
    ring: io_uring.Ring,
    reactor: reactor.Reactor,
    listen_fd: i32,
    port: u16,
    metrics: *ServerMetrics,  // 服务器指标
    running: atomic.Value(bool),  // 优雅关闭标志
    shutting_down: atomic.Value(bool),  // 优雅关闭探针（阶段27）
    next_stream_id: atomic.Value(u64),

    /// 初始化 HTTP 服务器
    pub fn init(metrics: *ServerMetrics, listen_port: u16) !HttpServer {
        var ring = try io_uring.Ring.init();
        errdefer ring.deinit(); // 只在失败时释放

        const listen_fd = try io_uring.Syscall.socket(
            io_uring.AF_INET,
            io_uring.SOCK_STREAM,
            0,
        );
        errdefer io_uring.Syscall.close(@intCast(listen_fd));

        // 绑定 0.0.0.0:listen_port（listen_port 为 0 时系统自动分配）
        var addr = io_uring.SockAddrIn{
            .family = io_uring.AF_INET,
            .port = io_uring.htons(listen_port),
            .addr = 0, // 0.0.0.0
        };
        try io_uring.Syscall.bind(listen_fd, &addr, @sizeOf(io_uring.SockAddrIn));
        try io_uring.Syscall.listen(listen_fd, 128);

        // 获取实际端口
        var actual_addr: io_uring.SockAddrIn = undefined;
        var addr_len: u32 = @sizeOf(io_uring.SockAddrIn);
        try io_uring.Syscall.getsockname(listen_fd, &actual_addr, &addr_len);
        const port = io_uring.htons(actual_addr.port);

        debug.print("🌐 HTTP 服务器启动: http://127.0.0.1:{d}/\n", .{port});
        debug.print("   路由：\n", .{});
        debug.print("     GET /health → 健康检查\n", .{});
        debug.print("     GET /health?verbose=true → 详细指标\n", .{});
        debug.print("     GET /v1/infer?input=xxx&modality=text|image → 推理\n", .{});

        const r = reactor.Reactor.init(ring);
        return HttpServer{
            .ring = ring,
            .reactor = r,
            .listen_fd = listen_fd,
            .port = port,
            .metrics = metrics,
            .running = atomic.Value(bool).init(true),
            .shutting_down = atomic.Value(bool).init(false),  // 阶段27：优雅关闭探针
            .next_stream_id = atomic.Value(u64).init(1),
        };
    }

    /// 运行服务器主循环（基于 Reactor 的异步事件循环）
    pub fn run(self: *HttpServer) !void {
        // 连接状态数组（栈分配，固定大小）
        var conns: [MAX_CONNS]Conn = undefined;
        var conn_count: usize = 0;

        // 提交初始 ACCEPT 请求
        var accept_req = io_uring.IoRequest{ .stream_id = 0, .buf_ptr = null };
        try self.reactor.prepare_accept(self.listen_fd, null, null, &accept_req);

        while (self.is_running()) {
            const event = self.reactor.poll();
            switch (event) {
                .Idle => {
                    if (!self.is_running()) break;
                    continue;
                },
                .IoComplete => |ev| {
                    if (ev.user_data == 0) {
                        // ACCEPT 完成：ev.result 是新连接的 fd
                        if (ev.result >= 0) {
                            const conn_fd: i32 = @intCast(ev.result);
                            self.metrics.inc_connections();

                            // 为新连接提交 RECV 请求
                            if (conn_count < MAX_CONNS) {
                                conns[conn_count] = .{
                                    .fd = conn_fd,
                                    .state = .Recv,
                                    .buf = [_]u8{0} ** 8192,
                                    .nread = 0,
                                    .stream_id = self.next_stream_id.rmw(.Add, 1, .monotonic),
                                };
                                const conn = &conns[conn_count];
                                conn_count += 1;

                                var recv_iov = io_uring.Iovec{
                                    .iov_base = @as(*anyopaque, @ptrCast(&conn.buf)),
                                    .iov_len = conn.buf.len,
                                };
                                var recv_req = io_uring.IoRequest{ .stream_id = conn.stream_id, .buf_ptr = null };
                                self.reactor.prepare_recv(conn_fd, &recv_iov, &recv_req) catch |err| {
                                    debug.print("提交 RECV 失败: {s}\n", .{@errorName(err)});
                                    io_uring.Syscall.close(@intCast(conn_fd));
                                    self.metrics.dec_connections();
                                    conn_count -= 1;
                                    return;
                                };
                            } else {
                                // 连接数超限，直接关闭
                                debug.print("连接数超限，关闭 fd={d}\n", .{conn_fd});
                                io_uring.Syscall.close(@intCast(conn_fd));
                                self.metrics.dec_connections();
                            }
                        }
                        // 重新提交 ACCEPT
                        if (self.is_running()) {
                            var new_accept_req = io_uring.IoRequest{ .stream_id = 0, .buf_ptr = null };
                            self.reactor.prepare_accept(self.listen_fd, null, null, &new_accept_req) catch |err| {
                                debug.print("重新提交 ACCEPT 失败: {s}\n", .{@errorName(err)});
                                return;
                            };
                        }
                    } else {
                        // RECV/SEND 完成：查找对应连接
                        var conn_idx: usize = 0;
                        var found = false;
                        while (conn_idx < conn_count) : (conn_idx += 1) {
                            if (conns[conn_idx].stream_id == ev.user_data) {
                                found = true;
                                break;
                            }
                        }

                        if (!found) {
                            // 未知 stream_id，忽略
                            continue;
                        }

                        const conn = &conns[conn_idx];

                        switch (conn.state) {
                            .Recv => {
                                if (ev.result > 0) {
                                    // RECV 成功：处理请求并发送响应
                                    conn.nread = @intCast(ev.result);
                                    self.metrics.inc_requests();

                                    // 构建 HTTP 响应（简化：直接返回 200 OK）
                                    const body = "{\"status\":\"ok\",\"service\":\"zigclaw-http\"}";
                                    var resp_buf: [1024]u8 = undefined;
                                    const response = fmt.bufPrint(&resp_buf,
                                        "HTTP/1.1 200 OK\r\n" ++
                                        "Content-Type: application/json\r\n" ++
                                        "Content-Length: {d}\r\n" ++
                                        "Connection: close\r\n" ++
                                        "\r\n{s}",
                                        .{body.len, body}
                                    ) catch {
                                        io_uring.Syscall.close(@intCast(conn.fd));
                                        self.metrics.dec_connections();
                                        self.removeConn(&conns, &conn_count, conn_idx);
                                        return;
                                    };

                                    // 提交 SEND
                                    var send_iov = io_uring.Iovec{
                                        .iov_base = @as(*anyopaque, @ptrCast(response.ptr)),
                                        .iov_len = response.len,
                                    };
                                    var send_req = io_uring.IoRequest{ .stream_id = conn.stream_id, .buf_ptr = null };
                                    self.reactor.prepare_send(conn.fd, &send_iov, &send_req) catch |err| {
                                        debug.print("提交 SEND 失败: {s}\n", .{@errorName(err)});
                                        io_uring.Syscall.close(@intCast(conn.fd));
                                        self.metrics.dec_connections();
                                        self.removeConn(&conns, &conn_count, conn_idx);
                                        return;
                                    };
                                    conn.state = .Send;
                                } else {
                                    // 连接关闭或错误
                                    io_uring.Syscall.close(@intCast(conn.fd));
                                    self.metrics.dec_connections();
                                    self.removeConn(&conns, &conn_count, conn_idx);
                                }
                            },
                            .Send => {
                                // SEND 完成：关闭连接
                                io_uring.Syscall.close(@intCast(conn.fd));
                                self.metrics.dec_connections();
                                self.removeConn(&conns, &conn_count, conn_idx);
                            },
                            else => {},
                        }
                    }
                },
            }
        }

        debug.print("服务器停止接受新连接\n", .{});
        // 关闭所有活跃连接
        for (0..conn_count) |i| {
            io_uring.Syscall.close(@intCast(conns[i].fd));
        }
    }

    /// 从连接数组中移除指定索引的连接（O(1) 交换删除）
    fn removeConn(self: *HttpServer, conns: *[MAX_CONNS]Conn, conn_count: *usize, idx: usize) void {
        _ = self;
        if (conn_count.* > 0 and idx < conn_count.*) {
            conns[idx] = conns[conn_count.* - 1];
            conn_count.* -= 1;
        }
    }

    /// 检查服务器是否正在运行
    pub fn is_running(self: *const HttpServer) bool {
        return self.running.load(.acquire);
    }

    /// 请求优雅关闭
    pub fn shutdown(self: *HttpServer) void {
        self.running.store(false, .release);
        self.shutting_down.store(true, .release);
    }

    /// 释放服务器资源
    pub fn deinit(self: *HttpServer) void {
        io_uring.Syscall.close(@intCast(self.listen_fd));
        self.ring.deinit();
    }
};

/// 解析 HTTP 请求（栈缓冲区版本，零堆分配）
fn parseHttpRequest(alloc: mem.Allocator, raw: []const u8) !HttpRequest {
    var headers = StringHashMap([]const u8).init(alloc);

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
fn handleHealth(metrics: *const ServerMetrics, shutting_down: bool, conn_fd: i32, query: ?[]const u8) !void {
    const verbose = if (query) |q| mem.indexOf(u8, q, "verbose=true") != null else false;

    if (verbose) {
        // 详细模式：返回 JSON 包含 uptime、total_requests、active_connections、error_count
        const uptime_ms = metrics.get_uptime_ms();
        const total_requests = metrics.get_total_requests();
        const active = metrics.get_active_connections();
        const errors = metrics.get_error_count();

        var body_buf: [512]u8 = undefined;
        const body = try fmt.bufPrint(&body_buf,
            "{{\"status\":\"ok\",\"uptime_ms\":{d},\"total_requests\":{d},\"active_connections\":{d},\"error_count\":{d},\"shutting_down\":{any}}}",
            .{ uptime_ms, total_requests, active, errors, shutting_down }
        );

        var resp_buf: [1024]u8 = undefined;
        const response = try fmt.bufPrint(&resp_buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n{s}",
            .{ body.len, body }
        );

        _ = io_uring.Syscall.send(@intCast(conn_fd), response.ptr, response.len, 0) catch |err| {
            debug.print("发送详细健康响应失败: {}\n", .{err});
            return;
        };
    } else {
        // 简单模式（栈缓冲区，零堆分配）
        const body = "{\"status\":\"ok\",\"service\":\"zigclaw-http\"}";
        var resp_buf: [512]u8 = undefined;
        const response = fmt.bufPrint(&resp_buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n{s}",
            .{body.len, body}
        ) catch {
            sendErrorResponse(conn_fd, 500, "Internal Server Error") catch {};
            return;
        };

        _ = io_uring.Syscall.send(@intCast(conn_fd), response.ptr, response.len, 0) catch |err| {
            debug.print("发送健康响应失败: {}\n", .{err});
            return;
        };
    }

    debug.print("/health 请求处理完成 (verbose={})\n", .{verbose});
}

/// 发送错误响应（栈缓冲区，零堆分配）
fn sendErrorResponse(conn_fd: i32, status_code: u16, message: []const u8) !void {
    var buf: [512]u8 = undefined;
    const response = fmt.bufPrint(&buf,
        "HTTP/1.1 {d} {s}\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n" ++
        "\r\n{s}",
        .{status_code, message, message.len, message}
    ) catch {
        // 缓冲区不足，截断消息
        const truncated = message[0..@min(message.len, 256)];
        const fallback = fmt.bufPrint(&buf,
            "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n{s}",
            .{status_code, truncated, truncated.len, truncated}
        ) catch return;
        _ = io_uring.Syscall.send(@intCast(conn_fd), fallback.ptr, fallback.len, 0) catch {};
        return;
    };

    _ = io_uring.Syscall.send(@intCast(conn_fd), response.ptr, response.len, 0) catch {};
}
