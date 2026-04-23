// src/integration_p5.zig
// ZigClaw V2.4 Phase5 | 单线程 + fake CQE | 暴露 buf_ptr=null 的伤口
const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const reactor_mod = @import("reactor.zig");
const protocol = @import("protocol.zig");

var test_body_pool = storage.BodyBufferPool.init();

const TEST_STREAM_ID: u64 = 42;

test "Phase5: 真实物理内存搬运 - 血管已打通，血肉注入" {
    var test_header = core.TokenStreamHeader.init();
    mem.writeInt(u64, test_header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, test_header.data[8..12], 100, .little);

    var window = storage.StreamWindow.init();
    window.push_header(test_header);

    // 伪造 CQ ring（存于堆栈，取地址传给 ring）
    var cq_ring: [16]io_uring.CqEntry = undefined;
    var cq_head: u32 = 0;
    var cq_tail: u32 = 0;

    // 初始化 proto
    var proto = protocol.Protocol.init(&window, &test_body_pool);

    // 把 fake CQ 指针注入 reactor.ring
    proto.reactor.ring.cqes = @as([*]io_uring.CqEntry, @ptrFromInt(@intFromPtr(&cq_ring)));
    proto.reactor.ring.cq_head = &cq_head;
    proto.reactor.ring.cq_tail = &cq_tail;

    // 写 fake CQE 1: header 读取完成
    cq_ring[0] = .{
        .user_data = TEST_STREAM_ID,
        .res = 12,
        .flags = 0,
    };
    cq_tail = 1;

    var step_count: u32 = 0;
    var got_complete: u32 = 0;

    while (step_count < 200) : (step_count += 1) {
        const event = proto.reactor.poll();
        if (event == .IoComplete) {
            got_complete += 1;
            // 第一次完成：写入第二个 fake CQE (body chunk)
            if (got_complete == 1) {
                cq_ring[1] = .{
                    .user_data = TEST_STREAM_ID + 1,
                    .res = 64,
                    .flags = 0,
                };
                cq_tail = 2;
            }
        }
        _ = proto.step();
        if (proto.state == .BodyDone) break;
    }

    // 预期 FAIL：buf_ptr == null，解引用会 null pointer dereference
    try testing.expect(proto.state == .BodyDone);
}
