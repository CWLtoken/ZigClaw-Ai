// src/http_protocol.zig
// ZigClaw V2.4 | 阶段23B | HTTP 协议处理器 - 直接使用 Reactor 走 io_uring
// 架构师红线：不得修改 protocol.zig/reactor.zig/io_uring.zig
// 设计：直接使用 Reactor 进行 HTTP I/O，实现 HTTP 状态机
const fmt = @import("std").fmt;
const heap = @import("std").heap;
const mem = @import("std").mem;
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");
const orchestrator = @import("orchestrator.zig");

// HTTP 请求解析状态
const HttpParseState = enum {
    RequestLine,  // 解析请求行（GET /path?query HTTP/1.1）
    Headers,      // 解析 HTTP 头
    Body,         // 解析 Body（如果有）
    Complete,     // 解析完成
};

// HTTP 请求结构
const HttpRequest = struct {
    method: []const u8,
    path: []const u8,
    query: ?[]const u8,
    headers: [64][2][]const u8, // 最多64个头
    header_count: usize,
    body: []const u8,
};

// HTTP 响应结构
const HttpResponse = struct {
    status_code: u16,
    status_text: []const u8,
    body: []const u8,
    content_type: []const u8,
};

// HTTP 协议处理器（直接使用 Reactor）
pub const HttpProtocolHandler = struct {
    reactor: reactor.Reactor,
    // 接收缓冲区
    recv_buf: [8192]u8,
    recv_len: usize,
    // 发送缓冲区
    send_buf: [4096]u8,
    send_len: usize,
    // 解析状态
    parse_state: HttpParseState,
    request: HttpRequest,
    response: HttpResponse,

    /// 初始化 HTTP 协议处理器
    pub fn init() !HttpProtocolHandler {
        const ring = try io_uring.Ring.init();
        const r = reactor.Reactor.init(ring);
        return HttpProtocolHandler{
            .reactor = r,
            .recv_buf = [_]u8{0} ** 8192,
            .recv_len = 0,
            .send_buf = [_]u8{0} ** 4096,
            .send_len = 0,
            .parse_state = .RequestLine,
            .request = HttpRequest{
                .method = "",
                .path = "",
                .query = null,
                .headers = undefined,
                .header_count = 0,
                .body = "",
            },
            .response = HttpResponse{
                .status_code = 200,
                .status_text = "OK",
                .body = "",
                .content_type = "application/json",
            },
        };
    }

    /// 处理 HTTP 请求（通过 Reactor 使用 io_uring I/O）
    pub fn handle_request(self: *HttpProtocolHandler, accepted_fd: i32) !void {
        // 1. 接收 HTTP 请求
        try self.recv_http_request(accepted_fd);
        
        // 2. 解析 HTTP 请求
        try self.parse_http_request();
        
        // 3. 处理请求（调用编排器）
        try self.process_request();
        
        // 4. 发送 HTTP 响应
        try self.send_http_response(accepted_fd);
    }

    /// 通过 io_uring 接收 HTTP 请求
    fn recv_http_request(self: *HttpProtocolHandler, fd: i32) !void {
        var iovec = io_uring.Iovec{
            .iov_base = &self.recv_buf,
            .iov_len = self.recv_buf.len,
        };
        var io_req = io_uring.IoRequest{
            .stream_id = 1, // 简化：固定 stream_id
            .buf_ptr = &self.recv_buf,
        };
        self.reactor.prepare_recv(fd, &iovec, &io_req);
        _ = try self.reactor.submit(1, 1); // 等待完成
        
        // 轮询获取结果
        while (true) {
            const event = self.reactor.poll();
            switch (event) {
                .IoComplete => |io| {
                    if (io.result == 0) {
                        return error.ConnectionClosed;
                    }
                    self.recv_len = io.result;
                    break;
                },
                .Idle => {
                    // 继续等待
                    continue;
                },
            }
        }
    }

    /// 解析 HTTP 请求（pub 函数，供测试使用）
    pub fn parse_http_request(self: *HttpProtocolHandler) !void {
        const data = self.recv_buf[0..self.recv_len];
        
        // 查找请求行结束位置
        const first_line_end = mem.indexOf(u8, data, "\r\n") orelse return error.InvalidRequest;
        const first_line = data[0..first_line_end];
        
        // 解析请求行：METHOD /path?query HTTP/1.1
        var iter = mem.splitSequence(u8, first_line, " ");
        const method = iter.next() orelse return error.InvalidRequest;
        const full_path = iter.next() orelse return error.InvalidRequest;
        _ = iter.next(); // 跳过 HTTP/1.1
        
        // 分离路径和查询参数
        var path = full_path;
        var query: ?[]const u8 = null;
        if (mem.indexOf(u8, full_path, "?")) |pos| {
            path = full_path[0..pos];
            query = full_path[pos + 1..];
        }
        
        self.request = HttpRequest{
            .method = method,
            .path = path,
            .query = query,
            .headers = undefined,
            .header_count = 0,
            .body = if (data.len > first_line_end + 2) data[first_line_end + 2..] else "",
        };
    }

    /// 处理请求（调用编排器进行推理）
    fn process_request(self: *HttpProtocolHandler) !void {
        // 只处理 /infer 路径
        if (!mem.eql(u8, self.request.path, "/infer")) {
            self.response = HttpResponse{
                .status_code = 404,
                .status_text = "Not Found",
                .body = "{\"error\":\"Not Found\"}",
                .content_type = "application/json",
            };
            return;
        }
        
        // 解析查询参数
        var input: ?[]const u8 = null;
        var modality: []const u8 = "text";
        if (self.request.query) |q| {
            var params = mem.splitSequence(u8, q, "&");
            while (params.next()) |param| {
                if (mem.startsWith(u8, param, "input=")) {
                    input = param[6..];
                } else if (mem.startsWith(u8, param, "modality=")) {
                    modality = param[9..];
                }
            }
        }
        
        if (input == null) {
            self.response = HttpResponse{
                .status_code = 400,
                .status_text = "Bad Request",
                .body = "{\"error\":\"Missing input parameter\"}",
                .content_type = "application/json",
            };
            return;
        }
        
        // 调用编排器进行推理（简化版，实际应调用 orchestrator.infer()）
        // 注意：这里避免导入 orchestrator，使用简化实现
        // ARCH-2: 使用栈缓冲区替代 page_allocator，零堆分配
        var response_buf: [1024]u8 = undefined;
        const response_body = fmt.bufPrint(
            &response_buf,
            "{{\"input\":\"{s}\",\"modality\":\"{s}\",\"result\":\"推理结果（暂未集成Orchestrator）\"}}",
            .{ input.?, modality }
        ) catch {
            self.response = HttpResponse{
                .status_code = 500,
                .status_text = "Internal Server Error",
                .body = "{\"error\":\"Response generation failed\"}",
                .content_type = "application/json",
            };
            return;
        };
        
        self.response = HttpResponse{
            .status_code = 200,
            .status_text = "OK",
            .body = response_body,
            .content_type = "application/json",
        };
    }

    /// 发送 HTTP 响应
    fn send_http_response(self: *HttpProtocolHandler, fd: i32) !void {
        // 构造 HTTP 响应
        const response_str = fmt.bufPrint(
            &self.send_buf,
            "HTTP/1.1 {d} {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "\r\n" ++
            "{s}",
            .{
                self.response.status_code,
                self.response.status_text,
                self.response.content_type,
                self.response.body.len,
                self.response.body,
            }
        ) catch {
            return error.ResponseTooLarge;
        };
        self.send_len = response_str.len;
        
        var iovec = io_uring.Iovec{
            .iov_base = &self.send_buf,
            .iov_len = self.send_len,
        };
        var io_req = io_uring.IoRequest{
            .stream_id = 2, // 简化：固定 stream_id
            .buf_ptr = &self.send_buf,
        };
        self.reactor.prepare_send(fd, &iovec, &io_req);
        _ = try self.reactor.submit(1, 1); // 等待完成
        
        // 轮询获取结果
        while (true) {
            const event = self.reactor.poll();
            switch (event) {
                .IoComplete => |io| {
                    if (io.result < 0) {
                        return error.SendFailed;
                    }
                    break;
                },
                .Idle => {
                    // 继续等待
                    continue;
                },
            }
        }
    }

    /// 释放资源
    pub fn deinit(self: *HttpProtocolHandler) void {
        self.reactor.ring.deinit(); // 注意：这里可能需要调整，因为 Reactor 持有 ring 副本
    }
};
