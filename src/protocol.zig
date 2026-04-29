// src/protocol.zig
// ZigClaw V2.4 | 系统大脑 | DMA自省 | ALU溢出防御 | Phase5真实内存搬运
const mem = @import("std").mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const reactor = @import("reactor.zig");
const io_uring = @import("io_uring.zig");
const router = @import("router.zig");

pub const State = union(enum) {
    Idle,
    HeaderRecv,
    BodyRecv,
    BodyDone,
    WaitingBusiness,  // 等待异步业务处理完成
    SendDone,
    Error: struct { reason: []const u8 },
};

pub const Protocol = struct {
    reactor: reactor.Reactor,
    window: *storage.StreamWindow,
    body_pool: *storage.BodyBufferPool,
    handler: router.HandlerFn,             // 同步业务处理器
    async_handler: ?router.AsyncHandlerFn, // 异步业务处理器（可选）
    state: State,
    active_stream_id: u64,
    accepted_fd: i32,                    // 网络连接 fd
    header_recv_buf: [13]u8,            // 报头接收暂存区（13 字节静态数组）
    recv_in_progress: bool,               // 避免重复提交 RECV
    current_io_req: io_uring.IoRequest,  // 当前 RECV/SEND 的 IoRequest（生命周期跟随 Protocol）
    current_iovec: io_uring.Iovec,       // 当前 RECV/SEND 的 iovec（生命周期跟随 Protocol）
    send_buf: [4096]u8,                 // 发送缓冲区（用于存储响应数据，与 router.RequestContext 同大小）
    response_ready: bool = false,         // 异步业务处理完成标志
    pending_ctx: ?router.RequestContext = null, // 保存待处理的请求上下文（异步路径）
    body_total_len: u32 = 0,             // 保存 body 总长度（从 header 中读取）

    pub fn init(window: *storage.StreamWindow, body_pool: *storage.BodyBufferPool, handler: router.HandlerFn) io_uring.SyscallError!Protocol {
        return .{
            .reactor = reactor.Reactor.init(try io_uring.Ring.init()),
            .window = window,
            .body_pool = body_pool,
            .handler = handler,
            .async_handler = null,
            .state = .Idle,
            .active_stream_id = 0,
            .accepted_fd = -1,
            .header_recv_buf = [_]u8{0} ** 13,
            .recv_in_progress = false,
            .current_io_req = undefined,
            .current_iovec = undefined,
            .send_buf = [_]u8{0} ** 4096,
            .response_ready = false,
        };
    }

    // 使用外部传入的 Ring（测试用，实现多连接事件循环）
    pub fn init_with_ring(
        window: *storage.StreamWindow,
        body_pool: *storage.BodyBufferPool,
        ring: *io_uring.Ring,
        handler: router.HandlerFn,
    ) !Protocol {
        return .{
            .reactor = reactor.Reactor.init(ring.*), // 复制 Ring 实例，共享底层 io_uring
            .window = window,
            .body_pool = body_pool,
            .handler = handler,
            .async_handler = null,
            .state = .Idle,
            .active_stream_id = 0,
            .accepted_fd = -1,
            .header_recv_buf = [_]u8{0} ** 13,
            .recv_in_progress = false,
            .current_io_req = undefined,
            .current_iovec = undefined,
            .send_buf = [_]u8{0} ** 4096,
            .response_ready = false,
        };
    }

    // onResponseReady：异步业务完成回调（静态函数）
    // 由 async_handler 在业务完成后调用
    pub fn onResponseReady(ctx: *router.RequestContext) void {
        const self = @as(*Protocol, @ptrCast(@alignCast(ctx.userdata.?)));
        self.response_ready = true;
    }

    pub fn step(self: *Protocol) State {
        switch (self.state) {
            .Idle => {},
            .HeaderRecv => {
                const event = self.reactor.poll();
                switch (event) {
                    .Idle => {
                        if (!self.recv_in_progress) {
                            // 主动提交 RECV 接收报头
                            self.current_iovec = io_uring.Iovec{
                                .iov_base = &self.header_recv_buf,
                                .iov_len = 13,
                            };
                            self.current_io_req = io_uring.IoRequest{
                                .stream_id = self.active_stream_id,
                                .buf_ptr = &self.header_recv_buf,
                            };
                            self.reactor.prepare_recv(self.accepted_fd, &self.current_iovec, &self.current_io_req);
                            _ = self.reactor.submit(1, 0) catch unreachable; // 非阻塞提交
                            self.recv_in_progress = true;
                        }
                    },
                    .IoComplete => |io| {
                        if (io.user_data != self.active_stream_id) {
                            self.state = .{ .Error = .{ .reason = "dma stream mismatch" } };
                            return self.state;
                        }
                        if (io.result != 13) {
                            self.state = .{ .Error = .{ .reason = "invalid header dma length" } };
                            return self.state;
                        }
                        // 将接收到的报头写入 window
                        var header = core.TokenStreamHeader.init();
                        @memcpy(&header.data, &self.header_recv_buf);
                        self.window.push_header(header);

                        const opt_header = self.window.access_header(self.active_stream_id);
                        if (opt_header == null) {
                            self.state = .{ .Error = .{ .reason = "header buffer missing" } };
                            return self.state;
                        }
                        const hdr = opt_header.?;
                        const dma_stream_id = mem.readInt(u64, hdr.data[0..8], .little);
                        if (dma_stream_id != self.active_stream_id) {
                            self.state = .{ .Error = .{ .reason = "dma memory corruption" } };
                            return self.state;
                        }
                        // 保存 body 总长度
                        self.body_total_len = mem.readInt(u32, hdr.data[8..12], .little);
                        self.recv_in_progress = false;
                        self.state = .BodyRecv;
                    },
                }
            },
            .BodyRecv => {
                const event = self.reactor.poll();
                switch (event) {
                    .Idle => {
                        if (!self.recv_in_progress) {
                            // 主动提交 RECV 接收 body
                            const dest_buf, const offset = self.body_pool.get_write_slice(self.active_stream_id);
                            _ = offset; // 忽略 offset
                            const opt_header = self.window.access_header(self.active_stream_id);
                            if (opt_header) |hdr| {
                                const remaining = mem.readInt(u32, hdr.data[8..12], .little);
                                if (remaining > 0) {
                                    self.current_iovec = io_uring.Iovec{
                                        .iov_base = dest_buf,
                                        .iov_len = remaining,
                                    };
                                    self.current_io_req = io_uring.IoRequest{
                                        .stream_id = self.active_stream_id,
                                        .buf_ptr = dest_buf,
                                    };
                                    self.reactor.prepare_recv(self.accepted_fd, &self.current_iovec, &self.current_io_req);
                                    _ = self.reactor.submit(1, 0) catch unreachable;
                                    self.recv_in_progress = true;
                                }
                            }
                        }
                    },
                    .IoComplete => |io| {
                        if (io.user_data != self.active_stream_id) {
                            self.state = .{ .Error = .{ .reason = "body stream mismatch" } };
                            return self.state;
                        }
                        const consumed = io.result;
                        const opt_header = self.window.access_header(self.active_stream_id);
                        if (opt_header == null) {
                            self.state = .{ .Error = .{ .reason = "header lost" } };
                            return self.state;
                        }
                        const header = opt_header.?;
                        const remaining = mem.readInt(u32, header.data[8..12], .little);
                        // Zig 0.16 语法：去掉类型参数
                        const new_len, const overflowed = @subWithOverflow(remaining, consumed);
                        if (overflowed != 0) {
                            self.state = .{ .Error = .{ .reason = "length underflow" } };
                            return self.state;
                        }

                        // 数据已经在 body_pool 缓冲区中（RECV 直接写入），无需 memcpy
                        // 只需更新写入位置
                        self.body_pool.advance(self.active_stream_id, consumed);

                        mem.writeInt(u32, header.data[8..12], new_len, .little);
                        if (new_len == 0) {
                            self.state = .BodyDone;
                        } else {
                            self.recv_in_progress = false; // 允许下次提交 RECV
                        }
                    },
                }
            },
            .BodyDone => {
                // 接收完成，调用业务处理器获取响应
                _ = self.window.access_header(self.active_stream_id) orelse {
                    self.state = .{ .Error = .{ .reason = "header lost before send" } };
                    return self.state;
                };

                // 构造 RequestContext
                const op_code = self.header_recv_buf[12]; // TokenStreamHeader 第 13 字节

                var ctx = router.RequestContext{
                    .stream_id = self.active_stream_id,
                    .op_code = op_code,
                    .body_pool = self.body_pool,
                    .response_buf = [_]u8{0} ** 4096,
                    .response_len = 0,
                    .userdata = null,
                    .body_len = self.body_total_len, // 设置 body 总长度
                };

                // 检查是否有异步处理器
                if (self.async_handler) |async_h| {
                    // 异步路径：保存 ctx，注册回调，进入 WaitingBusiness 状态
                    self.pending_ctx = ctx;
                    var pending_ptr = &self.pending_ctx.?;
                    pending_ptr.userdata = @ptrCast(self); // 存储 Protocol 指针，供回调使用
                    async_h(pending_ptr, onResponseReady); // 提交异步任务，立即返回
                    self.state = .WaitingBusiness;
                } else {
                    // 同步路径：直接调用处理器
                    self.handler(&ctx);

                    // 复制响应数据到 send_buf
                    @memcpy(self.send_buf[0..ctx.response_len], ctx.response_buf[0..ctx.response_len]);
                    const send_len = ctx.response_len;

                    // 提交 SEND
                    self.current_iovec = io_uring.Iovec{
                        .iov_base = &self.send_buf,
                        .iov_len = send_len,
                    };
                    self.current_io_req = io_uring.IoRequest{
                        .stream_id = self.active_stream_id,
                        .buf_ptr = &self.send_buf,
                    };
                    self.reactor.prepare_send(self.accepted_fd, &self.current_iovec, &self.current_io_req);
                    _ = self.reactor.submit(1, 0) catch unreachable;

                    // 进入 SendDone 状态
                    self.state = .SendDone;
                }
            },
            .WaitingBusiness => {
                // 等待异步业务处理完成
                if (self.response_ready) {
                    // 业务完成，获取保存的上下文
                    const ctx = &self.pending_ctx.?;

                    // 复制响应数据到 send_buf
                    @memcpy(self.send_buf[0..ctx.response_len], ctx.response_buf[0..ctx.response_len]);
                    const send_len = ctx.response_len;

                    // 提交 SEND
                    self.current_iovec = io_uring.Iovec{
                        .iov_base = &self.send_buf,
                        .iov_len = send_len,
                    };
                    self.current_io_req = io_uring.IoRequest{
                        .stream_id = self.active_stream_id,
                        .buf_ptr = &self.send_buf,
                    };
                    self.reactor.prepare_send(self.accepted_fd, &self.current_iovec, &self.current_io_req);
                    _ = self.reactor.submit(1, 0) catch unreachable;

                    // 清理状态
                    self.response_ready = false;
                    self.pending_ctx = null;

                    // 进入 SendDone 状态
                    self.state = .SendDone;
                }
            },
            .SendDone => {
                // 等待 SEND 完成
                const event = self.reactor.poll();
                switch (event) {
                    .Idle => {
                        // 等待中...
                    },
                    .IoComplete => |io| {
                        if (io.user_data != self.active_stream_id) {
                            self.state = .{ .Error = .{ .reason = "send stream mismatch" } };
                            return self.state;
                        }
                        // SEND 完成，SendDone 是终态
                        // 需要上层调用 reset() 才能回到 Idle
                    },
                }
            },
            .Error => {},
        }
        return self.state;
    }

    pub fn begin_receive(self: *Protocol, stream_id: u64, accepted_fd: i32, handler: router.HandlerFn, async_handler: ?router.AsyncHandlerFn) void {
        if (self.state == .Idle) {
            @atomicStore(u64, &self.active_stream_id, stream_id, .seq_cst);
            self.accepted_fd = accepted_fd;
            self.handler = handler;
            self.async_handler = async_handler;
            self.state = .HeaderRecv;
        }
    }

    /// 重置协议状态，释放当前流资源
    /// 调用后需重新 push_header + begin_receive 才能接收新流
    pub fn reset(self: *Protocol) void {
        // 释放当前流的 header（如果存在）
        if (self.active_stream_id != 0) {
            self.window.release_header(self.active_stream_id);
        }
        // 重置状态
        self.state = .Idle;
        self.active_stream_id = 0;
        self.accepted_fd = -1;
        self.recv_in_progress = false;
        // 注意：current_io_req 和 current_iovec 不需要清理
        // header_recv_buf 和 send_buf 会在下次接收/发送时覆盖
    }
};
