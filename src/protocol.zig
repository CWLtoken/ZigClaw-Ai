// src/protocol.zig
// ZigClaw V2.4 | 系统大脑 | DMA自省 | ALU溢出防御 | Phase5真实内存搬运
const mem = @import("std").mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const reactor = @import("reactor.zig");
const io_uring = @import("io_uring.zig");

pub const State = union(enum) {
    Idle,
    HeaderRecv,
    BodyRecv,
    BodyDone,
    Error: struct { reason: []const u8 },
};

pub const Protocol = struct {
    reactor: reactor.Reactor,
    window: *storage.StreamWindow,
    body_pool: *storage.BodyBufferPool,
    state: State,
    active_stream_id: u64,
    accepted_fd: i32,                    // 网络连接 fd
    header_recv_buf: [13]u8,            // 报头接收暂存区（13 字节静态数组）
    recv_in_progress: bool,               // 避免重复提交 RECV
    current_io_req: io_uring.IoRequest,  // 当前 RECV 的 IoRequest（生命周期跟随 Protocol）
    current_iovec: io_uring.Iovec,       // 当前 RECV 的 iovec（生命周期跟随 Protocol）

    pub fn init(window: *storage.StreamWindow, body_pool: *storage.BodyBufferPool) io_uring.SyscallError!Protocol {
        return .{
            .reactor = reactor.Reactor.init(try io_uring.Ring.init()),
            .window = window,
            .body_pool = body_pool,
            .state = .Idle,
            .active_stream_id = 0,
            .accepted_fd = -1,
            .header_recv_buf = [_]u8{0} ** 13,
            .recv_in_progress = false,
            .current_io_req = undefined,
            .current_iovec = undefined,
        };
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

                        if (io.buf_ptr != null) {
                            const src_ptr: [*]u8 = @ptrCast(io.buf_ptr.?);
                            const dest_ptr, const offset2 = self.body_pool.get_write_slice(self.active_stream_id);
                            _ = offset2;
                            @memcpy(dest_ptr[0..consumed], src_ptr[0..consumed]);
                            self.body_pool.advance(self.active_stream_id, consumed);
                        }

                        mem.writeInt(u32, header.data[8..12], new_len, .little);
                        if (new_len == 0) {
                            self.state = .BodyDone;
                        } else {
                            self.recv_in_progress = false; // 允许下次提交 RECV
                        }
                    },
                }
            },
            .BodyDone => {},
            .Error => {},
        }
        return self.state;
    }

    pub fn begin_receive(self: *Protocol, stream_id: u64, accepted_fd: i32) void {
        if (self.state == .Idle) {
            @atomicStore(u64, &self.active_stream_id, stream_id, .seq_cst);
            self.accepted_fd = accepted_fd;
            self.state = .HeaderRecv;
        }
    }
};