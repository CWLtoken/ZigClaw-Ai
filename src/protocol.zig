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

    pub fn init(window: *storage.StreamWindow, body_pool: *storage.BodyBufferPool) io_uring.SyscallError!Protocol {
        return .{
            .reactor = reactor.Reactor.init(if (io_uring.Ring.init()) |ring| ring else |e| return e),
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
                        if (io.result != @sizeOf(core.TokenStreamHeader)) {
                            self.state = .{ .Error = .{ .reason = "invalid header dma length" } };
                            return self.state;
                        }
                        const opt_header = self.window.access_header(self.active_stream_id);
                        if (opt_header) |header| {
                            const remaining_u32 = mem.readInt(u32, header.data[8..12], .little);
                            const usize_remaining = @as(usize, @intCast(remaining_u32));
                            const usize_consumed = @as(usize, @intCast(io.result));
                            if (usize_consumed > usize_remaining) {
                                self.state = .{ .Error = .{ .reason = "length underflow" } };
                                return self.state;
                            }
                            if (io.buf_ptr) |buf_ptr| {
                                const src_ptr: [*]u8 = @ptrCast(buf_ptr);
                                const write_slice = self.body_pool.get_write_slice(self.active_stream_id);
                                const dest_ptr = write_slice[0];
                                @memcpy(dest_ptr[0..usize_consumed], src_ptr[0..usize_consumed]);
                                self.body_pool.advance(self.active_stream_id, @as(u32, @intCast(usize_consumed)));
                            }
                            const usize_new_len = usize_remaining - usize_consumed;
                            mem.writeInt(u32, header.data[8..12], @as(u32, @intCast(usize_new_len)), .little);
                            if (usize_new_len == 0) {
                                self.state = .BodyDone;
                            } else {
                                self.state = .BodyRecv;
                            }
                        }
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
                        const io_result = io.result;
                        if (io_result < 0) {
                            self.state = .{ .Error = .{ .reason = "I/O error" } };
                            return self.state;
                        }
                        const opt_header = self.window.access_header(self.active_stream_id);
                        if (opt_header) |header| {
                            const remaining_u32 = mem.readInt(u32, header.data[8..12], .little);
                            const usize_remaining = @as(usize, @intCast(remaining_u32));
                            const usize_consumed = @as(usize, @intCast(io_result));
                            if (usize_consumed > usize_remaining) {
                                self.state = .{ .Error = .{ .reason = "length underflow" } };
                                return self.state;
                            }
                            if (io.buf_ptr) |buf_ptr| {
                                const src_ptr: [*]u8 = @ptrCast(buf_ptr);
                                const write_slice = self.body_pool.get_write_slice(self.active_stream_id);
                                const dest_ptr = write_slice[0];
                                @memcpy(dest_ptr[0..usize_consumed], src_ptr[0..usize_consumed]);
                                self.body_pool.advance(self.active_stream_id, @as(u32, @intCast(usize_consumed)));
                            }
                            const usize_new_len = usize_remaining - usize_consumed;
                            mem.writeInt(u32, header.data[8..12], @as(u32, @intCast(usize_new_len)), .little);
                            if (usize_new_len == 0) {
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