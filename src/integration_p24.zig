// src/integration_p24.zig
// ZigClaw V2.4 Phase12 | 压力测试 | 异常注入测试
const std = @import("std");
const router = @import("router.zig");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

fn push_cqe(ring: *io_uring.Ring, user_data: u64, res: i32) void {
    const tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    const idx = tail & ring.cq_ring_mask;
    ring.cqes[idx] = .{ .user_data = user_data, .res = res, .flags = 0 };
    @atomicStore(u32, ring.cq_tail, tail + 1, .release);
}

test "P24-S1: 客户端不发送数据（超时）" {
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();

    const stream_id: u64 = 7001;
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], stream_id, .little);
    window.push_header(header);

    var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring, router.default_handler);
    proto.begin_receive(stream_id, -1, router.default_handler, null);

    // 注入超时 CQE（ETIME = 62）
    var timeout_req = io_uring.IoRequest{ .stream_id = stream_id, .buf_ptr = undefined };
    push_cqe(&ring, @intFromPtr(&timeout_req), -62);

    const MaxIterations = 50;
    var iterations: u32 = 0;
    var recovered = false;

    while (iterations < MaxIterations and !recovered) {
        iterations += 1;
        const state = proto.step();

        if (state == .Error) {
            recovered = true;
            proto.reset();
        }

        _ = proto.reactor.submit(0, 0) catch 0;
    }

    try testing.expect(recovered); // 应该成功恢复
}

test "P24-S2: 客户端发送错误报头（stream_id 不匹配）" {
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();

    const stream_id: u64 = 7002;
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], stream_id, .little);
    window.push_header(header);

    var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring, router.default_handler);
    proto.begin_receive(stream_id, -1, router.default_handler, null);

    // 注入 CQE，但是使用错误的 stream_id
    var fake_hdr: [13]u8 align(64) = undefined;
    @memset(&fake_hdr, 0xAA);
    var wrong_req = io_uring.IoRequest{ .stream_id = 9999, .buf_ptr = &fake_hdr };
    push_cqe(&ring, @intFromPtr(&wrong_req), 13);

    const MaxIterations = 50;
    var iterations: u32 = 0;
    var handled = false;

    while (iterations < MaxIterations and !handled) {
        iterations += 1;
        const state = proto.step();

        if (state == .Error) {
            handled = true;
            proto.reset();
        }

        _ = proto.reactor.submit(0, 0) catch 0;
    }

    try testing.expect(handled); // 应该检测到错误并处理
}

test "P24-S3: 客户端中途断开（模拟 fd 关闭）" {
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();

    const stream_id: u64 = 7003;
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], stream_id, .little);
    window.push_header(header);

    var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring, router.default_handler);
    proto.begin_receive(stream_id, -1, router.default_handler, null);

    // 注入 HeaderRecv CQE
    var fake_hdr: [13]u8 align(64) = undefined;
    @memset(&fake_hdr, 0xAA);
    var io_req = io_uring.IoRequest{ .stream_id = stream_id, .buf_ptr = &fake_hdr };
    push_cqe(&ring, @intFromPtr(&io_req), 13);

    // 模拟客户端断开：注入错误 CQE（ECONNRESET = 104）
    var disconnect_req = io_uring.IoRequest{ .stream_id = stream_id, .buf_ptr = undefined };
    push_cqe(&ring, @intFromPtr(&disconnect_req), -104);

    const MaxIterations = 50;
    var iterations: u32 = 0;
    var recovered = false;

    while (iterations < MaxIterations and !recovered) {
        iterations += 1;
        const state = proto.step();

        if (state == .Error or state == .Idle) {
            recovered = true;
            if (state == .Error) {
                proto.reset();
            }
        }

        _ = proto.reactor.submit(0, 0) catch 0;
    }

    try testing.expect(recovered); // 应该成功恢复
}
