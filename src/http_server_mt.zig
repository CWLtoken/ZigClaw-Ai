// src/http_server_mt.zig
// ZigClaw V2.5 | 多线程 HTTP 服务器 — 方案 A：每线程自有 Reactor + SO_REUSEPORT
//
// 架构（显性直白）：
//   - N 个 worker 线程，每线程独立的 io_uring ring + Reactor + 连接池
//   - SO_REUSEPORT 内核级负载均衡（新连接自动分配到不同线程）
//   - 零共享状态：每线程独立事件循环，无锁、无原子操作（跨线程）
//   - 唯一共享：ServerMetrics（原子计数器，仅用于统计）
//
// 军规遵循：
//   - 精确子导入（无 const std = @import("std")）
//   - 无霉菌室规则（reactor/io_uring 禁止 try/catch/orelse）
//   - 零堆分配（连接池在栈上，仅 WorkerContext 在堆上）

const linux = @import("std").os.linux;
const c = @import("std").c;
const mem = @import("std").mem;
const fmt = @import("std").fmt;
const log = @import("std").log;
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");
const metrics_mod = @import("metrics.zig");

// pthread_t 使用 std.c 中的 opaque 类型
const pthread_t = c.pthread_t;

// ============================================================================
// 常量
// ============================================================================

const MAX_CONNS: usize = 256;
const RECV_BUF_SIZE: usize = 8192;
const MAX_BODY_SIZE: usize = RECV_BUF_SIZE;
const IDLE_TIMEOUT_MS: i64 = 30_000;
const SO_REUSEPORT: u32 = 15; // x86_64 Linux
const SOL_SOCKET: u32 = 1;

// ============================================================================
// 服务器指标（多线程安全）
// ============================================================================

pub const ServerMetrics = struct {
    uptime_start: i64,
    total_requests: metrics_mod.AlignedAtomicU64,
    active_connections: metrics_mod.AlignedAtomicU32,
    error_count: metrics_mod.AlignedAtomicU64,

    pub fn init() ServerMetrics {
        return .{
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
};

// ============================================================================
// 工具函数
// ============================================================================

fn getCurrentTimeMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
}

fn setSocketOption(fd: i32, level: u32, optname: u32, optval: u32) bool {
    const val_ptr: *const u32 = &optval;
    const rc = linux.syscall5(
        .setsockopt,
        @as(usize, @bitCast(@as(i64, fd))),
        @as(usize, level),
        @as(usize, optname),
        @intFromPtr(val_ptr),
        @sizeOf(u32),
    );
    return rc == 0;
}

// ============================================================================
// 连接状态
// ============================================================================

const ConnState = enum { Recv, Send, Done };

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
    last_active: i64,
};

// ============================================================================
// Worker 线程上下文
// ============================================================================

const WorkerContext = struct {
    thread_id: u32,
    ring: io_uring.Ring,
    reactor: reactor.Reactor,
    listen_fd: i32,
    port: u16,
    metrics: *ServerMetrics,
    conns: [MAX_CONNS]Conn,
    conn_count: usize,
    next_stream_id: u64,
    running: bool,

    pub fn init(
        thread_id: u32,
        listen_fd: i32,
        port_in: u16,
        metrics: *ServerMetrics,
    ) !WorkerContext {
        const ring = io_uring.Ring.init() catch |err| {
            log.err("Worker {d}: Ring.init 失败: {s}", .{ thread_id, @errorName(err) });
            return err;
        };
        const r = reactor.Reactor.init(ring);
        var ctx: WorkerContext = undefined;
        ctx.thread_id = thread_id;
        ctx.ring = ring;
        ctx.reactor = r;
        ctx.listen_fd = listen_fd;
        ctx.port = port_in;
        ctx.metrics = metrics;
        ctx.conn_count = 0;
        ctx.next_stream_id = @as(u64, thread_id) * 1_000_000 + 1;
        ctx.running = true;
        return ctx;
    }

    pub fn deinit(self: *WorkerContext) void {
        self.ring.deinit();
    }

    /// 运行 worker 事件循环
    pub fn run(self: *WorkerContext) !void {
        var accept_req = io_uring.IoRequest{ .stream_id = 0, .buf_ptr = null };
        if (self.reactor.prepare_accept(self.listen_fd, null, null, &accept_req)) {
            // accept 提交成功
        } else |err| {
            log.err("Worker {d}: prepare_accept 失败: {s}", .{ self.thread_id, @errorName(err) });
            return;
        }

        log.info("Worker {d}: 事件循环启动 (port={d})", .{ self.thread_id, self.port });

        while (self.running) {
            const event = self.reactor.poll();
            switch (event) {
                .Idle => {
                    self.scanTimeouts();
                    continue;
                },
                .IoComplete => |ev| {
                    if (ev.user_data == 0) {
                        if (ev.result >= 0) {
                            self.handleAccept(@intCast(ev.result));
                        }
                        if (self.running) {
                            var new_req = io_uring.IoRequest{ .stream_id = 0, .buf_ptr = null };
                            if (self.reactor.prepare_accept(self.listen_fd, null, null, &new_req)) {
                                // ok
                            } else |err| {
                                log.err("Worker {d}: 重新提交 ACCEPT 失败: {s}", .{ self.thread_id, @errorName(err) });
                                return;
                            }
                        }
                    } else {
                        self.handleIoComplete(reactor.Event{ .IoComplete = ev });
                    }
                },
            }
        }

        log.info("Worker {d}: 事件循环结束", .{ self.thread_id });
    }

    fn handleAccept(self: *WorkerContext, conn_fd: i32) void {
        if (self.conn_count >= MAX_CONNS) {
            io_uring.Syscall.close(@intCast(conn_fd));
            return;
        }

        self.metrics.inc_connections();

        self.conns[self.conn_count] = .{
            .fd = conn_fd,
            .state = .Recv,
            .buf = [_]u8{0} ** RECV_BUF_SIZE,
            .nread = 0,
            .stream_id = self.next_stream_id,
            .recv_iov = io_uring.Iovec{
                .iov_base = @as([*]u8, @ptrCast(&self.conns[self.conn_count].buf)),
                .iov_len = RECV_BUF_SIZE,
            },
            .recv_req = io_uring.IoRequest{ .stream_id = self.next_stream_id, .buf_ptr = null },
            .send_iov = io_uring.Iovec{ .iov_base = undefined, .iov_len = 0 },
            .send_req = io_uring.IoRequest{ .stream_id = 0, .buf_ptr = null },
            .last_active = getCurrentTimeMs(),
        };

        self.next_stream_id += 1;
        const conn = &self.conns[self.conn_count];
        self.conn_count += 1;

        if (self.reactor.prepare_recv(conn_fd, &conn.recv_iov, &conn.recv_req)) {
            // ok
        } else |err| {
            log.warn("Worker {d}: prepare_recv 失败: {s}", .{ self.thread_id, @errorName(err) });
            io_uring.Syscall.close(@intCast(conn.fd));
            self.metrics.dec_connections();
            self.conn_count -= 1;
        }
    }

    fn handleIoComplete(self: *WorkerContext, ev: reactor.Event) void {
        const io = switch (ev) {
            .IoComplete => |*payload| payload,
            else => return,
        };
        var conn_idx: usize = 0;
        while (conn_idx < self.conn_count) {
            if (self.conns[conn_idx].stream_id == io.user_data) break;
            conn_idx += 1;
        }
        if (conn_idx >= self.conn_count) return;

        const conn = &self.conns[conn_idx];

        switch (conn.state) {
            .Recv => {
                if (io.result > 0) {
                    if (io.result > MAX_BODY_SIZE) {
                        log.warn("Worker {d}: 请求体过大: {d}", .{ self.thread_id, io.result });
                        self.closeConn(conn_idx);
                        return;
                    }
                    conn.nread = @intCast(io.result);
                    conn.last_active = getCurrentTimeMs();
                    self.metrics.inc_requests();

                    const response = self.routeAndRespond(conn.buf[0..conn.nread]);

                    var send_iov = io_uring.Iovec{
                        .iov_base = @constCast(response.ptr),
                        .iov_len = response.len,
                    };
                    var send_req = io_uring.IoRequest{ .stream_id = conn.stream_id, .buf_ptr = null };
                    if (self.reactor.prepare_send(conn.fd, &send_iov, &send_req)) {
                        conn.state = .Send;
                    } else |err| {
                        log.warn("Worker {d}: prepare_send 失败: {s}", .{ self.thread_id, @errorName(err) });
                        self.closeConn(conn_idx);
                    }
                } else {
                    self.closeConn(conn_idx);
                }
            },
            .Send => {
                self.closeConn(conn_idx);
            },
            else => {},
        }
    }

    fn closeConn(self: *WorkerContext, idx: usize) void {
        if (idx >= self.conn_count) return;
        io_uring.Syscall.close(@intCast(self.conns[idx].fd));
        self.metrics.dec_connections();
        self.removeConn(idx);
    }

    fn removeConn(self: *WorkerContext, idx: usize) void {
        if (self.conn_count > 0 and idx < self.conn_count) {
            self.conns[idx] = self.conns[self.conn_count - 1];
            self.conn_count -= 1;
        }
    }

    fn scanTimeouts(self: *WorkerContext) void {
        const now = getCurrentTimeMs();
        var i: usize = 0;
        while (i < self.conn_count) {
            if (now - self.conns[i].last_active > IDLE_TIMEOUT_MS) {
                log.info("Worker {d}: 连接 {d} 超时", .{ self.thread_id, self.conns[i].stream_id });
                self.closeConn(i);
            } else {
                i += 1;
            }
        }
    }

    fn routeAndRespond(self: *WorkerContext, raw: []u8) []const u8 {
        const first_line_end = mem.indexOf(u8, raw, "\r\n") orelse raw.len;
        const first_line = raw[0..first_line_end];
        var iter = mem.splitSequence(u8, first_line, " ");
        _ = iter.next();
        const full_path = iter.next() orelse "/";
        var path: []const u8 = full_path;
        if (mem.indexOf(u8, full_path, "?")) |pos| {
            path = full_path[0..pos];
        }
        if (mem.eql(u8, path, "/health")) return self.handleHealth();
        if (mem.eql(u8, path, "/metrics")) return self.handleMetrics();
        return self.handleNotFound();
    }

    fn handleHealth(_: *WorkerContext) []const u8 {
        var buf: [512]u8 = undefined;
        const body = "{\"status\":\"ok\",\"service\":\"zigclaw-mt\"}";
        const response = fmt.bufPrint(&buf,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{body.len, body}
        ) catch return "HTTP/1.1 500 Internal Server Error\r\n\r\n";
        return response;
    }

    fn handleMetrics(_: *WorkerContext) []const u8 {
        var buf: [2048]u8 = undefined;
        const len = metrics_mod.formatMetrics(&buf) catch {
            return "HTTP/1.1 500 Internal Server Error\r\n\r\n";
        };
        var resp_buf: [4096]u8 = undefined;
        const response = fmt.bufPrint(&resp_buf,
            "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{len, buf[0..len]}
        ) catch return "HTTP/1.1 500 Internal Server Error\r\n\r\n";
        return response;
    }

    fn handleNotFound(_: *WorkerContext) []const u8 {
        return "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 26\r\nConnection: close\r\n\r\n{\"error\":\"Not Found\"}";
    }
};

// ============================================================================
// Worker 线程入口
// ============================================================================

fn workerThreadEntry(arg: ?*anyopaque) callconv(.c) ?*anyopaque {
    const ctx: *WorkerContext = @ptrCast(@alignCast(arg orelse unreachable));
    ctx.run() catch |err| {
        log.err("Worker {d}: 异常: {s}", .{ ctx.thread_id, @errorName(err) });
    };
    ctx.deinit();
    // 释放 WorkerContext（由主线程分配）
    const page_alloc = @import("std").heap.page_allocator;
    page_alloc.destroy(ctx);
    return null;
}

// ============================================================================
// 多线程 HTTP 服务器
// ============================================================================

pub const HttpServerMT = struct {
    metrics: ServerMetrics,
    port: u16,
    num_workers: u32,
    listen_fds: []i32,
    threads: []pthread_t,
    contexts: []*WorkerContext,

    pub fn init(port: u16, num_workers: u32) !HttpServerMT {
        var metrics = ServerMetrics.init();
        metrics.uptime_start = getCurrentTimeMs();

        const page_alloc = @import("std").heap.page_allocator;

        var listen_fds = try page_alloc.alloc(i32, num_workers);
        errdefer page_alloc.free(listen_fds);

        const threads = try page_alloc.alloc(pthread_t, num_workers);
        errdefer page_alloc.free(threads);

        var contexts = try page_alloc.alloc(*WorkerContext, num_workers);
        errdefer page_alloc.free(contexts);

        for (0..num_workers) |i| {
            const fd = io_uring.Syscall.socket(io_uring.AF_INET, io_uring.SOCK_STREAM, 0) catch |err| {
                log.err("Worker {d}: socket 失败: {s}", .{ i, @errorName(err) });
                for (0..i) |j| io_uring.Syscall.close(@intCast(listen_fds[j]));
                return err;
            };

            _ = setSocketOption(fd, SOL_SOCKET, SO_REUSEPORT, 1);

            var addr = io_uring.SockAddrIn{
                .family = io_uring.AF_INET,
                .port = io_uring.htons(port),
                .addr = 0,
            };
            io_uring.Syscall.bind(fd, &addr, @sizeOf(io_uring.SockAddrIn)) catch |err| {
                log.err("Worker {d}: bind 失败: {s}", .{ i, @errorName(err) });
                io_uring.Syscall.close(@intCast(fd));
                for (0..i) |j| io_uring.Syscall.close(@intCast(listen_fds[j]));
                return err;
            };

            io_uring.Syscall.listen(fd, 128) catch |err| {
                log.err("Worker {d}: listen 失败: {s}", .{ i, @errorName(err) });
                io_uring.Syscall.close(@intCast(fd));
                for (0..i) |j| io_uring.Syscall.close(@intCast(listen_fds[j]));
                return err;
            };

            listen_fds[i] = fd;
            contexts[i] = undefined; // 在 start() 中初始化
        }

        return .{
            .metrics = metrics,
            .port = port,
            .num_workers = num_workers,
            .listen_fds = listen_fds,
            .threads = threads,
            .contexts = contexts,
        };
    }

    pub fn start(self: *HttpServerMT) !void {
        const page_alloc = @import("std").heap.page_allocator;

        for (0..self.num_workers) |i| {
            const ctx = try page_alloc.create(WorkerContext);
            ctx.* = try WorkerContext.init(@intCast(i), self.listen_fds[i], self.port, &self.metrics);
            self.contexts[i] = ctx;

            const rc = c.pthread_create(&self.threads[i], null, workerThreadEntry, @ptrCast(@alignCast(ctx)));
            if (rc != .SUCCESS) {
                log.err("Worker {d}: pthread_create 失败", .{i});
                return error.ThreadCreateFailed;
            }
            log.info("Worker {d}: 已启动", .{i});
        }
    }

    pub fn join(self: *HttpServerMT) void {
        for (0..self.num_workers) |i| {
            _ = c.pthread_join(self.threads[i], null);
            log.info("Worker {d}: 已停止", .{i});
        }
    }

    pub fn deinit(self: *HttpServerMT) void {
        const page_alloc = @import("std").heap.page_allocator;
        for (0..self.num_workers) |i| {
            io_uring.Syscall.close(@intCast(self.listen_fds[i]));
        }
        page_alloc.free(self.listen_fds);
        page_alloc.free(self.threads);
        page_alloc.free(self.contexts);
    }
};
