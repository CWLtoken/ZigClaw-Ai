// src/integration_p5.zig
// ZigClaw V2.4 Phase5 | 真实物理内存搬运测试 | 血管打通+血肉注入
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Thread = std.Thread;
const Io = std.Io;
const Semaphore = Io.Semaphore;

const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

const TEST_STREAM_ID: u64 = 42;
const TEST_TOTAL_BODY_LEN: u32 = 100;
const HEADER_DMA_LEN: u32 = 13;
const BODY_CHUNK1_LEN: u32 = 40;
const BODY_CHUNK2_LEN: u32 = 60;

var test_body_pool = storage.BodyBufferPool.init();

const TestContext = struct {
    proto: *protocol.Protocol,
    consumer_ready: Semaphore,
    producer_done: Semaphore,
    is_running: bool,
    io: Io,
};

test "Phase5: 真实物理内存搬运 - 血管已打通，血肉注入" {
    var window = storage.StreamWindow.init();
    var test_header = core.TokenStreamHeader.init();
    mem.writeInt(u64, test_header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, test_header.data[8..12], TEST_TOTAL_BODY_LEN, .little);
    window.push_header(test_header);

    var proto = protocol.Protocol.init(&window, &test_body_pool);
    var ctx = TestContext{
        .proto = &proto,
        .consumer_ready = .{},
        .producer_done = .{},
        .is_running = true,
        .io = testing.io,
    };

    const producer_thread = try Thread.spawn(.{}, producer_real_memory_loop, .{&ctx});
    defer producer_thread.join();

    proto.begin_receive(TEST_STREAM_ID);
    while (ctx.is_running) {
        const state = proto.step();
        switch (state) {
            .Idle => {},
            .HeaderRecv => {
                ctx.consumer_ready.post(ctx.io);
                ctx.producer_done.wait(ctx.io) catch {};
            },
            .BodyRecv => {
                ctx.consumer_ready.post(ctx.io);
                ctx.producer_done.wait(ctx.io) catch {};
            },
            .BodyDone => {
                ctx.is_running = false;
            },
            .Error => |e| {
                std.debug.panic("state machine error: {s}", .{e.reason});
            },
        }
    }

    try testing.expect(proto.state == .BodyDone);
    const final_hdr = window.access_header(TEST_STREAM_ID).?;
    const final_len = mem.readInt(u32, final_hdr.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_len);

    const slot_idx = @mod(TEST_STREAM_ID, 1024);
    for (test_body_pool.buffers[slot_idx][0..40]) |b| {
        try testing.expectEqual(@as(u8, 'A'), b);
    }
    for (test_body_pool.buffers[slot_idx][40..100]) |b| {
        try testing.expectEqual(@as(u8, 'B'), b);
    }

    test_body_pool = storage.BodyBufferPool.init();
}

fn producer_real_memory_loop(ctx: *TestContext) !void {
    ctx.consumer_ready.waitUncancelable(ctx.io);
    const tail1 = @atomicLoad(u32, ctx.proto.reactor.ring.sq_tail, .acquire);
    const idx1 = tail1 & io_uring.SQ_MASK;
    ctx.proto.reactor.ring.sq_entries[idx1] = .{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null,
        .buf_len = HEADER_DMA_LEN,
        .offset = 0,
        .user_data = TEST_STREAM_ID,
    };
    @atomicStore(u32, ctx.proto.reactor.ring.sq_tail, tail1 + 1, .release);
    ctx.producer_done.post(ctx.io);

    ctx.consumer_ready.waitUncancelable(ctx.io);
    const tail2 = @atomicLoad(u32, ctx.proto.reactor.ring.sq_tail, .acquire);
    const idx2 = tail2 & io_uring.SQ_MASK;
    var fake_body_chunk1 = [_]u8{'A'} ** BODY_CHUNK1_LEN;
    ctx.proto.reactor.ring.sq_entries[idx2] = .{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = @as(?*anyopaque, @ptrCast(&fake_body_chunk1)),
        .buf_len = BODY_CHUNK1_LEN,
        .offset = 0,
        .user_data = TEST_STREAM_ID,
    };
    @atomicStore(u32, ctx.proto.reactor.ring.sq_tail, tail2 + 1, .release);
    ctx.producer_done.post(ctx.io);

    ctx.consumer_ready.waitUncancelable(ctx.io);
    const tail3 = @atomicLoad(u32, ctx.proto.reactor.ring.sq_tail, .acquire);
    const idx3 = tail3 & io_uring.SQ_MASK;
    var fake_body_chunk2 = [_]u8{'B'} ** BODY_CHUNK2_LEN;
    ctx.proto.reactor.ring.sq_entries[idx3] = .{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = @as(?*anyopaque, @ptrCast(&fake_body_chunk2)),
        .buf_len = BODY_CHUNK2_LEN,
        .offset = 0,
        .user_data = TEST_STREAM_ID,
    };
    @atomicStore(u32, ctx.proto.reactor.ring.sq_tail, tail3 + 1, .release);
    ctx.producer_done.post(ctx.io);
}
