// src/integration_p25.zig
// ZigClaw V2.4 Phase13 | 全链路业务闭环 | 最小验证
const std = @import("std");
const router = @import("router.zig");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");
const inference = @import("inference.zig");

fn push_cqe_proto(proto: *protocol.Protocol, user_data: u64, res: i32) void {
    const ring = &proto.reactor.ring;
    const tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    const idx = tail & ring.cq_ring_mask;
    ring.cqes[idx] = .{ .user_data = user_data, .res = res, .flags = 0 };
    @atomicStore(u32, ring.cq_tail, tail + 1, .release);
}

test "P25: 推理业务处理器集成测试（最小验证）" {
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();

    const stream_id: u64 = 25001;
    
    var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring, inference.inference_handler);
    
    // 检查 begin_receive 后的状态
    proto.begin_receive(stream_id, -1, inference.inference_handler, null);
    try testing.expectEqual(protocol.State.HeaderRecv, proto.state);

    // 准备 fake header
    var fake_hdr: [13]u8 align(64) = undefined;
    mem.writeInt(u64, fake_hdr[0..8], stream_id, .little);
    const prompt = "Hello, ZigClaw!";
    mem.writeInt(u32, fake_hdr[8..12], @intCast(prompt.len), .little);
    
    var io_req = io_uring.IoRequest{ .stream_id = stream_id, .buf_ptr = &fake_hdr };

    // 注入 HeaderRecv CQE
    push_cqe_proto(&proto, @intFromPtr(&io_req), 13);

    // 处理 HeaderRecv -> BodyRecv
    var state = proto.step();
    // 状态可能是 BodyRecv（如果 poll() 看到了 CQE）或 HeaderRecv（如果还没处理）
    try testing.expect(state == .BodyRecv or state == .HeaderRecv);

    // 注入 BodyRecv CQE
    var fake_body: [4096]u8 align(64) = undefined;
    @memcpy(fake_body[0..prompt.len], prompt);
    io_req.buf_ptr = &fake_body;
    push_cqe_proto(&proto, @intFromPtr(&io_req), @intCast(prompt.len));

    // 处理 BodyRecv，等待 BodyDone
    var iterations: u32 = 0;
    var body_done = false;
    while (iterations < 100 and !body_done) {
        iterations += 1;
        state = proto.step();
        if (state == .BodyDone) body_done = true;
        _ = proto.reactor.submit(0, 0) catch 0;
    }
    try testing.expect(body_done);
    
    // 简化验证：至少完成了 BodyDone，没有进入 Error
    try testing.expect(state != .Error);
    
    // 清理
    proto.reset();
    try testing.expectEqual(@as(u64, 0), window.len);
}
