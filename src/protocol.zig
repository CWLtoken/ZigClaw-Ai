// src/protocol.zig
// ZigClaw V2.4 | 系统大脑 | DMA自省 | ALU溢出防御 | Phase5真实内存搬运
const mem = @import("std").mem;
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

    pub fn init(window: *storage.StreamWindow, body_pool: *storage.BodyBufferPool) io_uring.SyscallError!Protocol {
        return .{
            .reactor = reactor.Reactor.init(try io_uring.Ring.init()),
            .window = window,
            .body_pool = body_pool,
            .state = .Idle,
            .active_stream_id = 0,
        };
    }

    // P15: 使用外部传入的 Ring（避免内部创建新 Ring）
    pub fn init_with_ring(window: *storage.StreamWindow, body_pool: *storage.BodyBufferPool, ring: *io_uring.Ring) io_uring.SyscallError!Protocol {
        return .{
            .reactor = reactor.Reactor.init(ring.*),  // 复制 Ring 实例
            .window = window,
            .body_pool = body_pool,
            .state = .Idle,
            .active_stream_id = 0,
        };
    }

    pub fn step(self: *Protocol) State {
        switch (self.state) {
            .Idle => {},
            .HeaderRecv => {
                const event = self.reactor.poll();
                switch (event) {
                    .Idle => {},
                    .IoComplete => |io| {
                        if (io.user_data != self.active_stream_id) {
                            self.state = .{ .Error = .{ .reason = "dma stream mismatch" } };
                            return self.state;
                        }
                        if (io.result != 13) {
                            self.state = .{ .Error = .{ .reason = "invalid header dma length" } };
                            return self.state;
                        }
                        const opt_header = self.window.access_header(self.active_stream_id);
                        if (opt_header == null) {
                            self.state = .{ .Error = .{ .reason = "header buffer missing" } };
                            return self.state;
                        }
                        const header = opt_header.?;
                        const dma_stream_id = mem.readInt(u64, header.data[0..8], .little);
                        if (dma_stream_id != self.active_stream_id) {
                            self.state = .{ .Error = .{ .reason = "dma memory corruption" } };
                            return self.state;
                        }
                        self.state = .BodyRecv;
                    },
                }
            },
            .BodyRecv => {
                const event = self.reactor.poll();
                switch (event) {
                    .Idle => {},
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
                        // 【已修复】Zig 0.16 语法：去掉类型参数
                        const new_len, const overflowed = @subWithOverflow(remaining, consumed);
                        if (overflowed != 0) {
                            self.state = .{ .Error = .{ .reason = "length underflow" } };
                            return self.state;
                        }

                        if (io.buf_ptr != null) {
                            const src_ptr: [*]u8 = @ptrCast(io.buf_ptr.?);
                            const dest_ptr, const offset = self.body_pool.get_write_slice(self.active_stream_id);
                            // 【已修复】告诉编译器：我们故意不用 offset
                            _ = offset;
                            @memcpy(dest_ptr[0..consumed], src_ptr[0..consumed]);
                            self.body_pool.advance(self.active_stream_id, consumed);
                        }

                        mem.writeInt(u32, header.data[8..12], new_len, .little);
                        if (new_len == 0) {
                            self.state = .BodyDone;
                        }
                    },
                }
            },
            .BodyDone => {},
            .Error => {},
        }
        return self.state;
    }

    pub fn begin_receive(self: *Protocol, stream_id: u64) void {
        if (self.state == .Idle) {
            @atomicStore(u64, &self.active_stream_id, stream_id, .seq_cst);
            self.state = .HeaderRecv;
        }
    }
};