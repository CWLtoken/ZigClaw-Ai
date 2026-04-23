// src/integration_p4.zig
// ZigClaw V2.4 Phase4 | SPSC 跨线程原子有效性验证 | 严格时序裸逻辑
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Thread = std.Thread;
const Semaphore = Thread.Semaphore;

const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

const TEST_STREAM_ID: u64 = 42;
const TEST_TOTAL_BODY_LEN: u32 = 100;
const HEADER_DMA_LEN: u32 = 13;
const BODY_CHUNK1_LEN: u32 = 40;
const BODY_CHUNK2_LEN: u32 = 60;

const TestContext = struct {
    proto: *protocol.Protocol,
    consumer_ready: Semaphore,
    producer_done: Semaphore,
    is_running: bool,
};

test "Phase4: SPSC 跨线程原子指针有效性验证 - 严格时序Happy Path" {
    var window = storage.StreamWindow.init();
    var test_header = core.TokenStreamHeader.init();
    mem.writeInt(u64, test_header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, test_header.data[8..12], TEST_TOTAL_BODY_LEN, .little);
    window.push_header(test_header);

    var proto = protocol.Protocol.init(&window);

    var ctx = TestContext{
        .proto = &proto,
        .consumer_ready = Semaphore{},
        .producer_done = Semaphore{},
        .is_running = true,
    };

    const producer_thread = try Thread.spawn(.{}, producer_hardcode_loop, .{&ctx});
    defer producer_thread.join();

    proto.begin_receive(TEST_STREAM_ID);

    while (ctx.is_running) {
        const current_state = proto.step();
        switch (current_state) {
            .Idle => {},
            .HeaderRecv => {
                ctx.consumer_ready.post();
                ctx.producer_done.wait();
            },
            .BodyRecv => {
                ctx.consumer_ready.post();
                ctx.producer_done.wait();
            },
            .BodyDone => {
                ctx.is_running = false;
            },
            .Error => |err| {
                ctx.is_running = false;
                try testing.expectFmt(null, "state machine error: {s}", .{err.reason});
            },
        }
    }

    try testing.expectEqual(protocol.State.BodyDone, proto.state);
    const final_header = window.access_header(TEST_STREAM_ID).?;
    const final_remaining_len = mem.readInt(u32, final_header.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_remaining_len);
}

fn producer_hardcode_loop(ctx: *TestContext) !void {
    ctx.consumer_ready.wait();
    const sq_tail_1 = @atomicLoad(u32, &ctx.proto.reactor.ring.sq_tail, .acquire);
    const idx_1 = sq_tail_1 & io_uring.SQ_MASK;
    ctx.proto.reactor.ring.sq_entries[idx_1] = .{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null,
        .buf_len = HEADER_DMA_LEN,
        .offset = 0,
        .user_data = TEST_STREAM_ID,
    };
    @atomicStore(u32, &ctx.proto.reactor.ring.sq_tail, sq_tail_1 + 1, .release);
    ctx.producer_done.post();

    ctx.consumer_ready.wait();
    const sq_tail_2 = @atomicLoad(u32, &ctx.proto.reactor.ring.sq_tail, .acquire);
    const idx_2 = sq_tail_2 & io_uring.SQ_MASK;
    ctx.proto.reactor.ring.sq_entries[idx_2] = .{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null,
        .buf_len = BODY_CHUNK1_LEN,
        .offset = 0,
        .user_data = TEST_STREAM_ID,
    };
    @atomicStore(u32, &ctx.proto.reactor.ring.sq_tail, sq_tail_2 + 1, .release);
    ctx.producer_done.post();

    ctx.consumer_ready.wait();
    const sq_tail_3 = @atomicLoad(u32, &ctx.proto.reactor.ring.sq_tail, .acquire);
    const idx_3 = sq_tail_3 & io_uring.SQ_MASK;
    ctx.proto.reactor.ring.sq_entries[idx_3] = .{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null,
        .buf_len = BODY_CHUNK2_LEN,
        .offset = 0,
        .user_data = TEST_STREAM_ID,
    };
    @atomicStore(u32, &ctx.proto.reactor.ring.sq_tail, sq_tail_3 + 1, .release);
    ctx.producer_done.post();
}
