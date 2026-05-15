// src/http_server.zig
// ZigClaw V2.4 | 阶段23C | 故障恢复与可观测性
// 架构升级：run() 改为基于 Reactor 的异步事件循环
const std = @import("std");
const atomic = std.atomic;
const debug = std.debug;
const fmt = std.fmt;
const heap = std.heap;
const log = std.log;
const mem = std.mem;
const StringHashMap = std.StringHashMap;
const linux = std.os.linux;
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");
const context = @import("context.zig");
const middleware = @import("entry/middleware.zig");
const metrics_mod = @import("metrics.zig");
const http_log = @import("http_log.zig");
const ibus = @import("ibus.zig");

// 服务器指标（缓存行对齐原子变量，消除伪共享）
// 使用 AlignedAtomicU64/AlignedAtomicU32 确保多核/多线程下
// Reactor 线程频繁 fetch-add total_requests 时，不会与监控线程
// 读取 error_count 产生 L1 缓存互相驱逐（伪共享）
pub const ServerMetrics = struct {
    uptime_start: i64,
    total_requests: metrics_mod.AlignedAtomicU64,
    active_connections: metrics_mod.AlignedAtomicU32,
    error_count: metrics_mod.AlignedAtomicU64,

    pub fn init() ServerMetrics {
        return ServerMetrics{
            .uptime_start = 0,
            .total_requests = metrics_mod.AlignedAtomicU64.init(0),
            .active_connections = metrics_mod.AlignedAtomicU32.init(0),
            .error_count = metrics_mod.AlignedAtomicU64.init(0),
        };
    }

    pub fn inc_requests(self: *ServerMetrics) void {
        _ = self.total_requests.fetchAdd(1, .monotonic);
    }

    pub fn inc_connections(self: *ServerMetrics) void {
        _ = self.active_connections.fetchAdd(1, .monotonic);
    }

    pub fn dec_connections(self: *ServerMetrics) void {
        _ = self.active_connections.fetchSub(1, .monotonic);
    }

    pub fn inc_errors(self: *ServerMetrics) void {
        _ = self.error_count.fetchAdd(1, .monotonic);
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
    buf: [RECV_BUF_SIZE]u8,
    nread: usize,
    stream_id: u64,
    recv_iov: io_uring.Iovec,
    recv_req: io_uring.IoRequest,
    send_iov: io_uring.Iovec,
    send_req: io_uring.IoRequest,
    last_active: i64, // 最后活跃时间（毫秒），用于超时检测（SEC-6）
};

/// 最大并发连接数（栈分配，固定大小）
const MAX_CONNS: usize = 256;

/// 接收缓冲区大小（8KB，栈分配，与 MAX_BODY_SIZE 一致）
const RECV_BUF_SIZE: usize = 8192;

/// 最大请求体大小（8KB，防止溢出攻击）
const MAX_BODY_SIZE: usize = RECV_BUF_SIZE;

/// 连接空闲超时（30秒）
const IDLE_TIMEOUT_MS: i64 = 30_000;

/// 滑动窗口限流器（SEC-4，零堆分配）
const RateLimiter = struct {
    window_start: metrics_mod.AlignedAtomicU64,
    count: metrics_mod.AlignedAtomicU64,
    const WINDOW_NS: u64 = 1_000_000_000; // 1秒
    const MAX_REQUESTS: u64 = 100; // 每秒最多100请求

    pub fn init() RateLimiter {
        return .{
            .window_start = metrics_mod.AlignedAtomicU64.init(0),
            .count = metrics_mod.AlignedAtomicU64.init(0),
        };
    }

    pub fn allow(self: *RateLimiter) bool {
        const now = @as(u64, @intCast(std.time.milliTimestamp()));
        const start = self.window_start.load(.acquire);
        if (now - start >= WINDOW_NS / 1000) {
            // 新窗口，重置计数
            _ = self.window_start.store(now, .release);
            _ = self.count.store(1, .release);
            return true;
        }
        const current = self.count.fetchAdd(1, .monotonic);
        return current < MAX_REQUESTS;
    }
};

pub const HttpServer = struct {
    ring: io_uring.Ring,
    reactor: reactor.Reactor,
    listen_fd: i32,
    port: u16,
    metrics: *ServerMetrics,  // 服务器指标
    running: atomic.Value(bool),  // 优雅关闭标志
    shutting_down: atomic.Value(bool),  // 优雅关闭探针（阶段27）
    next_stream_id: atomic.Value(u64),
    rate_limiter: RateLimiter,  // 滑动窗口限流器（SEC-4）

    /// 初始化 HTTP 服务器
    pub fn init(metrics: *ServerMetrics, listen_port: u16) !HttpServer {
        var ring = io_uring.Ring.init() catch |err| {
            debug.print("Ring.init 失败: {s}\n", .{@errorName(err)});
            return err;
        };

        const listen_fd = io_uring.Syscall.socket(
            io_uring.AF_INET,
            io_uring.SOCK_STREAM,
            0,
        ) catch |err| {
            debug.print("socket 失败: {s}\n", .{@errorName(err)});
            ring.deinit();
            return err;
        };
        errdefer ring.deinit();

        // 绑定 0.0.0.0:listen_port（listen_port 为 0 时系统自动分配）
        var addr = io_uring.SockAddrIn{
            .family = io_uring.AF_INET,
            .port = io_uring.htons(listen_port),
            .addr = 0, // 0.0.0.0
        };
        io_uring.Syscall.bind(listen_fd, &addr, @sizeOf(io_uring.SockAddrIn)) catch |err| {
            debug.print("bind 失败: {s}\n", .{@errorName(err)});
            io_uring.Syscall.close(@intCast(listen_fd));
            return err;
        };
        io_uring.Syscall.listen(listen_fd, 128) catch |err| {
            debug.print("listen 失败: {s}\n", .{@errorName(err)});
            io_uring.Syscall.close(@intCast(listen_fd));
            return err;
        };

        // 获取实际端口
        var actual_addr: io_uring.SockAddrIn = undefined;
        var addr_len: u32 = @sizeOf(io_uring.SockAddrIn);
        io_uring.Syscall.getsockname(listen_fd, &actual_addr, &addr_len) catch |err| {
            debug.print("getsockname 失败: {s}\n", .{@errorName(err)});
            io_uring.Syscall.close(@intCast(listen_fd));
            return err;
        };
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
            .rate_limiter = RateLimiter.init(),
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
                    // SEC-6: 连接超时检查（Idle 时扫描超时连接）
                    const now = getCurrentTimeMs();
                    var i: usize = 0;
                    while (i < conn_count) {
                        if (now - conns[i].last_active > IDLE_TIMEOUT_MS) {
                            log.info("Connection {d} timed out", .{conns[i].stream_id});
                            io_uring.Syscall.close(@intCast(conns[i].fd));
                            self.metrics.dec_connections();
                            self.removeConn(&conns, &conn_count, i);
                        } else {
                            i += 1;
                        }
                    }
                    continue;
                },
                .IoComplete => |ev| {
                    if (ev.user_data == 0) {
                        // ACCEPT 完成：ev.result 是新连接的 fd
                        if (ev.result >= 0) {
                            const conn_fd: i32 = @intCast(ev.result);

                            // SEC-4: Rate Limiting 检查
                            if (!self.rate_limiter.allow()) {
                                log.warn("Rate limit exceeded, closing connection", .{});
                                io_uring.Syscall.close(@intCast(conn_fd));
                                continue;
                            }

                            self.metrics.inc_connections();

                            // 为新连接提交 RECV 请求
                            if (conn_count < MAX_CONNS) {
                                conns[conn_count] = .{
                                    .fd = conn_fd,
                                    .state = .Recv,
                                    .buf = [_]u8{0} ** RECV_BUF_SIZE,
                                    .nread = 0,
                                    .stream_id = self.next_stream_id.rmw(.Add, 1, .monotonic),
                                    .recv_iov = io_uring.Iovec{
                                        .iov_base = @as([*]u8, @ptrCast(&conns[conn_count].buf)),
                                        .iov_len = conns[conn_count].buf.len,
                                    },
                                    .recv_req = io_uring.IoRequest{ .stream_id = conns[conn_count].stream_id, .buf_ptr = null },
                                    .send_iov = io_uring.Iovec{ .iov_base = undefined, .iov_len = 0 },
                                    .send_req = io_uring.IoRequest{ .stream_id = 0, .buf_ptr = null },
                                    .last_active = getCurrentTimeMs(),
                                };
                                const conn = &conns[conn_count];
                                conn_count += 1;

                                self.reactor.prepare_recv(conn_fd, &conn.recv_iov, &conn.recv_req) catch |err| {
                                    debug.print("提交 RECV 失败: {s}\\n", .{@errorName(err)});
                                    io_uring.Syscall.close(@intCast(conn.fd));
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
                                    // SEC-5: 请求体大小限制
                                    if (ev.result > MAX_BODY_SIZE) {
                                        log.warn("Request body too large: {d} bytes", .{ev.result});
                                        io_uring.Syscall.close(@intCast(conn.fd));
                                        self.metrics.dec_connections();
                                        self.removeConn(&conns, &conn_count, conn_idx);
                                        continue;
                                    }

                                    // RECV 成功：解析请求并路由
                                    conn.nread = @intCast(ev.result);
                                    conn.last_active = getCurrentTimeMs();
                                    self.metrics.inc_requests();

                                    // 解析请求行（简化：只取第一行）
                                    const raw = conn.buf[0..conn.nread];
                                    const first_line_end = mem.indexOf(u8, raw, "\r\n") orelse raw.len;
                                    const first_line = raw[0..first_line_end];

                                    // 解析 "METHOD /path HTTP/1.1"
                                    var iter = mem.splitSequence(u8, first_line, " ");
                                    const method = iter.next() orelse "";
                                    const full_path = iter.next() orelse "/";
                                    _ = method;

                                    // 分离路径和查询
                                    var path: []const u8 = full_path;
                                    var query: ?[]const u8 = null;
                                    if (mem.indexOf(u8, full_path, "?")) |pos| {
                                        path = full_path[0..pos];
                                        query = full_path[pos + 1 ..];
                                    }

                                    // 路由分发
                                    const response = self.routeAndRespond(path, query, raw[first_line_end..]);

                                    // 提交 SEND
                                    var send_iov = io_uring.Iovec{
                                        .iov_base = @constCast(response.ptr),
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

    /// 路由并生成响应（零堆分配，栈缓冲区）
    fn routeAndRespond(self: *HttpServer, path: []const u8, query: ?[]const u8, _body: []const u8) []const u8 {
        _ = _body;
        // /health 端点
        if (mem.eql(u8, path, "/health")) {
            return self.handleHealth(query);
        }
        // /metrics 端点（T2 修复：分离缓冲区，杜绝重叠）
        if (mem.eql(u8, path, "/metrics")) {
            return self.handleMetrics();
        }
        // /v1/infer 端点（占位）
        if (mem.eql(u8, path, "/v1/infer")) {
            return self.handleInferPlaceholder();
        }
        // 默认 404
        return self.handleNotFound();
    }

    /// 处理 /health 请求
    fn handleHealth(self: *HttpServer, query: ?[]const u8) []const u8 {
        const verbose = if (query) |q| mem.indexOf(u8, q, "verbose=true") != null else false;
        var buf: [1024]u8 = undefined;

        if (verbose) {
            const uptime_ms = self.metrics.get_uptime_ms();
            const total_requests = self.metrics.get_total_requests();
            const active = self.metrics.get_active_connections();
            const errors = self.metrics.get_error_count();
            const body = fmt.bufPrint(&buf,
                "{{\"status\":\"ok\",\"uptime_ms\":{d},\"total_requests\":{d},\"active_connections\":{d},\"error_count\":{d},\"shutting_down\":{any}}}",
                .{ uptime_ms, total_requests, active, errors, self.shutting_down.load(.acquire) }
            ) catch return self.handleNotFound();
            return self.buildJsonResponse(&buf, body);
        } else {
            const body = "{\"status\":\"ok\",\"service\":\"zigclaw-http\"}";
            return self.buildJsonResponse(&buf, body);
        }
    }

    /// 处理 /metrics 请求（T2 修复：使用分离缓冲区）
    fn handleMetrics(self: *HttpServer) []const u8 {
        // 缓冲区1：用于 formatMetrics 输出（避免与响应缓冲区重叠）
        var metrics_buf: [2048]u8 = undefined;
        const metrics_len = metrics_mod.formatMetrics(&metrics_buf) catch {
            return self.handleServerError();
        };

        // 缓冲区2：用于构建 HTTP 响应（与 metrics_buf 完全分离）
        var resp_buf: [4096]u8 = undefined;
        const response = fmt.bufPrint(&resp_buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/plain; version=0.0.4\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            SECURITY_HEADERS ++
            "\r\n{s}",
            .{ metrics_len, metrics_buf[0..metrics_len] }
        ) catch return self.handleServerError();

        return response;
    }

    /// 处理 /v1/infer 占位
    fn handleInferPlaceholder(self: *HttpServer) []const u8 {
        var buf: [512]u8 = undefined;
        // SEC-7: 错误信息不泄露内部状态
        const body = "{\"error\":\"Service Unavailable\",\"detail\":\"inference module not connected\"}";
        return self.buildJsonResponse(&buf, body);
    }

    /// 安全响应头（SEC-6）
    const SECURITY_HEADERS: []const u8 =
        "X-Content-Type-Options: nosniff\r\n" ++
        "X-Frame-Options: DENY\r\n" ++
        "X-XSS-Protection: 1; mode=block\r\n";

    /// 404 Not Found
    fn handleNotFound(self: *HttpServer) []const u8 {
        // SEC-12: 记录 404 请求便于安全审计
        _ = self;
        log.warn("404 Not Found", .{});
        return "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 26\r\nConnection: close\r\n" ++ SECURITY_HEADERS ++ "\r\n{\"error\":\"Not Found\"}";
    }

    /// 500 Internal Server Error
    fn handleServerError(self: *HttpServer) []const u8 {
        // SEC-12: 记录 500 错误便于安全审计
        _ = self;
        log.err("500 Internal Server Error", .{});
        return "HTTP/1.1 500 Internal Server Error\r\nContent-Type: text/plain\r\nContent-Length: 21\r\nConnection: close\r\n" ++ SECURITY_HEADERS ++ "\r\nInternal Server Error";
    }

    /// 构建 JSON 响应（辅助函数）
    fn buildJsonResponse(self: *HttpServer, buf: []u8, body: []const u8) []const u8 {
        _ = self;
        const response = fmt.bufPrint(buf,
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Connection: close\r\n" ++
            SECURITY_HEADERS ++
            "\r\n{s}",
            .{body.len, body}
        ) catch return "HTTP/1.1 500 Internal Server Error\r\n\r\n";
        return response;
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
