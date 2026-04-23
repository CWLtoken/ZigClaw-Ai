// src/integration_p4.zig
// ZigClaw V2.4 Phase4 | 单线程简化版 | 暴露 poll() 返回 Idle 的伤口
const std = @import("std");
const testing = std.testing;
const mem = std.mem;

const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

var test_body_pool = storage.BodyBufferPool.init();

const TEST_STREAM_ID: u64 = 42;

test "Phase4: SPSC 跨线程原子指针有效性验证 - 严格时序Happy Path" {
    var window = storage.StreamWindow.init();
    var test_header = core.TokenStreamHeader.init();
    mem.writeInt(u64, test_header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, test_header.data[8..12], 100, .little);
    window.push_header(test_header);

    var proto = protocol.Protocol.init(&window, &test_body_pool);
    proto.begin_receive(TEST_STREAM_ID);

    // 单线程：直接调用 step()，不依赖 CQ 中有 CQE
    var step_count: u32 = 0;
    while (step_count < 100) {
        step_count += 1;
        _ = proto.step();
        // s 永远是 .Idle 或 .HeaderRecv（poll() 读空 CQ）
        // 不调用 wait()，不会死锁
    }

    // 状态永远到不了 .BodyDone → 断言失败，暴露伤口
    try testing.expect(proto.state == .BodyDone);
}
