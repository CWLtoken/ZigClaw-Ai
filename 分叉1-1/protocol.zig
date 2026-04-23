// src/protocol.zig
// ZigClaw V2.4 | 系统大脑 | DMA自省 | ALU溢出防御 | Phase5修正内存序
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

    pub fn init(window: *storage.StreamWindow, body_pool: *storage.BodyBufferPool) Protocol {
        return .{
            .reactor = reactor.Reactor.init(io_uring.Ring.init()),
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
                        // 校验1:流ID强绑定
                        if (io.user_data != self.active_stream_id) {
                            self.state = .{ .Error = .{ .reason = "dma stream mismatch" } };
                            return self.state;
                        }
                        // 校验2:固定13字节报头
                        if (io.result != 13) {
                            self.state = .{ .Error = .{ .reason = "invalid header dma length" } };
                            return self.state;
                        }
                        // 校验3:缓冲区存在性
                        const opt_header = self.window.access_header(self.active_stream_id);
                        if (opt_header == null) {
                            self.state = .{ .Error = .{ .reason = "header buffer missing" } };
                            return self.state;
                        }
                        const header = opt_header.?;
                        // 校验4:DMA内存完整性
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
                        // 校验1:流ID强绑定
                        if (io.user_data != self.active_stream_id) {
                            self.state = .{ .Error = .{ .reason = "body stream mismatch" } };
                            return self.state;
                        }
                        // 校验2:报头未丢失
                        const opt_header = self.window.access_header(self.active_stream_id);
                        if (opt_header == null) {
                            self.state = .{ .Error = .{ .reason = "header lost" } };
                            return self.state;
                        }
                        const header = opt_header.?;
                        const remaining = mem.readInt(u32, header.data[8..12], .little);
                        const consumed = io.result;
                        // 校验3:ALU溢出直连死亡
                        const new_len, const overflowed = @subWithOverflow(u32, remaining, consumed);
                        if (overflowed != 0) {
                            self.state = .{ .Error = .{ .reason = "length underflow" } };
                            return self.state;
                        }

                        // ==========================================
                        // Phase5 新增：真实物理内存搬运（血管已打通）
                        // 保留if判空：HeaderRecv不走此分支，io.buf_ptr在Header阶段为null
                        // ==========================================
                        if (io.buf_ptr != null) {
                            // 1. 裸切anyopaque指针：撕开伪装，回归真实
                            const src_ptr: [*]u8 = @ptrCast(io.buf_ptr.?);
                            // 2. 获取池子写入位置：裸指针返回，无封装
                            const dest_ptr, const _ = self.body_pool.get_write_slice(self.active_stream_id);
                            // 3. 物理搬运：把硬件发来的字节强行拷进池子
                            @memcpy(dest_ptr[0..consumed], src_ptr[0..consumed]);
                            // 4. 推进池子偏移量：允许覆盖，真实段错误惩罚
                            self.body_pool.advance(self.active_stream_id, consumed);
                        }

                        // 仅Protocol有权修改物理内存（报头长度）
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
            // Phase5修正：.SeqCst→.seqcst（严格小写内存序）
            @atomicStore(u64, &self.active_stream_id, stream_id, .seqcst);
            self.state = .HeaderRecv;
        }
    }
};