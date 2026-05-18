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
    Error: struct { code: u32 },
};

// SEC-7: 错误码映射表（不暴露内部状态）
const ErrorCode = enum(u32) {
    success = 0,
    dma_stream_mismatch = 1,
    invalid_header_length = 2,
    length_underflow = 3,
    body_pool_full = 4,
    body_stream_mismatch = 5,
    io_error = 6,
};

fn errorToCode(err: []const u8) u32 {
    // 将内部错误描述为不透明错误码
    _ = err;
    return 0; // 默认未知错误
}

pub const Protocol = struct {
    reactor: reactor.Reactor,
    window: *storage.StreamWindow,
    body_pool: *storage.BodyBufferPool,
    state: State,
    active_stream_id: u64,
    body_slot: ?storage.BodyBufferPool.SlotHandle = null,

    pub fn init(window: *storage.StreamWindow, body_pool: *storage.BodyBufferPool) io_uring.SyscallError!Protocol {
        return .{
            .reactor = reactor.Reactor.init(if (io_uring.Ring.init()) |ring| ring else |e| return e),
            .window = window,
            .body_pool = body_pool,
            .state = .Idle,
            .active_stream_id = 0,
            .body_slot = null,
        };
    }

    pub fn step(self: *Protocol) State {
        switch (self.state) {
            .Idle => {},
            .HeaderRecv => {
                const event: reactor.Event = self.reactor.poll();
                switch (event) {
                    .Idle => {},
                    .IoComplete => |io| {
                        if (io.user_data != self.active_stream_id) {
                            self.state = .{ .Error = .{ .code = 1 } };
                            return self.state;
                        }
                        if (io.result != @sizeOf(core.TokenStreamHeader)) {
                            self.state = .{ .Error = .{ .code = 2 } };
                            return self.state;
                        }
                        const opt_header = self.window.access_header(self.active_stream_id);
                        if (opt_header) |header| {
                            const remaining_u32: u32 = mem.readInt(u32, header.data[8..12], .little);
                            const consumed: u32 = @intCast(io.result);
                            if (consumed > remaining_u32) {
                                self.state = .{ .Error = .{ .code = 3 } };
                                return self.state;
                            }
                            if (io.buf_ptr) |buf_ptr| {
                                const src_ptr: [*]u8 = @ptrCast(buf_ptr);
                                const opt_write_slice = self.body_pool.get_write_slice(self.active_stream_id);
                                if (opt_write_slice) |result|
                                {
                                    const dest_ptr = result[0];
                                    const handle = result[1];
                                    const usize_consumed: usize = @intCast(consumed);
                                    @memcpy(dest_ptr[0..usize_consumed], src_ptr[0..usize_consumed]);
                                    self.body_pool.advance(handle, consumed);
                                    self.body_slot = handle;
                                }
                                else
                                {
                                    self.state = .{ .Error = .{ .code = 4 } };
                                    return self.state;
                                }
                            }
                            const new_len: u32 = remaining_u32 - consumed;
                            mem.writeInt(u32, header.data[8..12], new_len, .little);
                            if (new_len == 0) {
                                self.state = .BodyDone;
                            } else {
                                self.state = .BodyRecv;
                            }
                        }
                    },
                }
            },
            .BodyRecv => {
                const event: reactor.Event = self.reactor.poll();
                switch (event) {
                    .Idle => {},
                    .IoComplete => |io| {
                        if (io.user_data != self.active_stream_id) {
                            self.state = .{ .Error = .{ .code = 5 } };
                            return self.state;
                        }
                        const io_result: i64 = io.result;
                        if (io_result < 0) {
                            self.state = .{ .Error = .{ .code = 6 } };
                            return self.state;
                        }
                        const opt_header = self.window.access_header(self.active_stream_id);
                        if (opt_header) |header| {
                            const remaining_u32: u32 = mem.readInt(u32, header.data[8..12], .little);
                            const consumed: u32 = @intCast(io_result);
                            if (consumed > remaining_u32) {
                                self.state = .{ .Error = .{ .code = 3 } };
                                return self.state;
                            }
                            if (io.buf_ptr) |buf_ptr| {
                                const src_ptr: [*]u8 = @ptrCast(buf_ptr);
                                const opt_write_slice = self.body_pool.get_write_slice(self.active_stream_id);
                                if (opt_write_slice) |result|
                                {
                                    const dest_ptr = result[0];
                                    const handle = result[1];
                                    const usize_consumed: usize = @intCast(consumed);
                                    @memcpy(dest_ptr[0..usize_consumed], src_ptr[0..usize_consumed]);
                                    self.body_pool.advance(handle, consumed);
                                    self.body_slot = handle;
                                }
                                else
                                {
                                    self.state = .{ .Error = .{ .code = 4 } };
                                    return self.state;
                                }
                            }
                            const new_len: u32 = remaining_u32 - consumed;
                            mem.writeInt(u32, header.data[8..12], new_len, .little);
                            if (new_len == 0) {
                                self.state = .BodyDone;
                            }
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
