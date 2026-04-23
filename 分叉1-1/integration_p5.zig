// src/integration_p5.zig
// ZigClaw V2.4 Phase5 | 真实物理内存搬运测试 | 修正内存序+移除栈炸弹
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

// ==========================================
// Phase5修正：模块级BSS段分配，禁止压栈（移除4MB栈炸弹）
// ==========================================
var test_body_pool = storage.BodyBufferPool.init();

const TestContext = struct {
    proto: *protocol.Protocol,
    consumer_ready: Semaphore,
    producer_done: Semaphore,
    is_running: bool,
};

test "Phase5: 真实物理内存搬运 - 血管已打通，血肉注入" {
    // 1. 初始化存储池 + 报头
    var window = storage.StreamWindow.init();
    var test_header = core.TokenStreamHeader.init();
    mem.writeInt(u64, test_header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, test_header.data[8..12], TEST_TOTAL_BODY_LEN, .little);
    window.push_header(test_header);

    // 2. 初始化状态机（传入模块级池子，无栈炸弹）
    var proto = protocol.Protocol.init(&window, &test_body_pool);
    var ctx = TestContext{
        .proto = &proto,
        .consumer_ready = Semaphore{ .permits = 0 },
        .producer_done = Semaphore{ .permits = 0 },
        .is_running = true,
    };

    // 3. 启动生产者线程（构造真实字节数组，血肉注入）
    const producer_thread = try Thread.spawn(.{}, producer_real_memory_loop, .{&ctx});
    defer producer_thread.join();

    // ========== 消费者主线程：真实消费，血肉搬运 ==========
    proto.begin_receive(TEST_STREAM_ID);
    while (ctx.is_running) {
        const state = proto.step();
        switch (state) {
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
            .Error => |e| {
                std.debug.panic("状态机错误: {s}", .{e.reason});
            },
        }
    }

    // ========== 双重验证：账本正确 + 血肉数据正确 ==========
    // 验证1：长度归零（记账正确）
    const final_hdr = window.access_header(TEST_STREAM_ID).?;
    const final_len = mem.readInt(u32, final_hdr.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_len);

    // 验证2：去池子挖出血肉数据，验证真实写入（血管已打通）
    const slot_idx = @mod(TEST_STREAM_ID, 1024);
    // 验证前40字节是'A'
    for (test_body_pool.buffers[slot_idx][0..40])|b| { 
        try testing.expectEqual(@as(u8, 'A'), b); 
    }
    // 验证后60字节是'B'
    for (test_body_pool.buffers[slot_idx][40..100])|b| { 
        try testing.expectEqual(@as(u8, 'B'), b); 
    }

    // ==========================================
    // Phase5修正：测试结束后重置池子，为下次测试准备
    // ==========================================
    test_body_pool = storage.BodyBufferPool.init();

    std.debug.print("\n✅ Phase5 测试通过：血管已打通，100字节真实落盘\n", .{});
}

// 生产者线程：构造真实栈上字节数组，指针塞进buf_ptr，血肉注入
fn producer_real_memory_loop(ctx: *TestContext) !void {
    // ---------------- 第1步：投递Header（13字节，buf_ptr仍为null） ----------------
    ctx.consumer_ready.wait();
    // Phase5修正：.Acquire→.acquire（严格小写内存序）
    const tail1 = @atomicLoad(u32, &ctx.proto.reactor.ring.sq_tail, .acquire);
    const idx1 = tail1 & io_uring.SQ_MASK;
    ctx.proto.reactor.ring.sq_entries[idx1] = .{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = null, // Header无业务数据，保持null
        .buf_len = HEADER_DMA_LEN,
        .offset = 0,
        .user_data = TEST_STREAM_ID,
    };
    // Phase5修正：.Release→.release（严格小写内存序）
    @atomicStore(u32, &ctx.proto.reactor.ring.sq_tail, tail1 + 1, .release);
    ctx.producer_done.post();

    // ---------------- 第2步：投递Body块1（40字节，真实'A'数组，血肉注入） ----------------
    ctx.consumer_ready.wait();
    const tail2 = @atomicLoad(u32, &ctx.proto.reactor.ring.sq_tail, .acquire);
    const idx2 = tail2 & io_uring.SQ_MASK;
    
    // 【关键】构造真实栈上字节数组：40个'A'，不再是空气
    var fake_body_chunk1 = [_]u8{'A'} ** BODY_CHUNK1_LEN;
    
    ctx.proto.reactor.ring.sq_entries[idx2] = .{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = @ptrCast(&fake_body_chunk1), // 真实指针塞进buf_ptr，血肉注入
        .buf_len = BODY_CHUNK1_LEN,
        .offset = 0,
        .user_data = TEST_STREAM_ID,
    };
    @atomicStore(u32, &ctx.proto.reactor.ring.sq_tail, tail2 + 1, .release);
    ctx.producer_done.post();

    // ---------------- 第3步：投递Body块2（60字节，真实'B'数组，血肉注入） ----------------
    ctx.consumer_ready.wait();
    const tail3 = @atomicLoad(u32, &ctx.proto.reactor.ring.sq_tail, .acquire);
    const idx3 = tail3 & io_uring.SQ_MASK;
    
    // 【关键】构造真实栈上字节数组：60个'B'，不再是空气
    var fake_body_chunk2 = [_]u8{'B'} ** BODY_CHUNK2_LEN;
    
    ctx.proto.reactor.ring.sq_entries[idx3] = .{
        .op_code = @intFromEnum(io_uring.IOOp.Read),
        .fd = 0,
        .buf_ptr = @ptrCast(&fake_body_chunk2), // 真实指针塞进buf_ptr，血肉注入
        .buf_len = BODY_CHUNK2_LEN,
        .offset = 0,
        .user_data = TEST_STREAM_ID,
    };
    @atomicStore(u32, &ctx.proto.reactor.ring.sq_tail, tail3 + 1, .release);
    ctx.producer_done.post();
}