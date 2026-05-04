// src/integration_p33.zig
// ZigClaw V2.4 | Keep-Alive 连接复用完整验证 | 单连接双请求测试
const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");
const storage = @import("storage.zig");
const router = @import("router.zig");
const core = @import("core.zig");

test "P33: Keep-Alive 单连接双请求完整验证" {
    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();
    
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);
    
    const accepted_fd: i32 = 100;
    var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring, router.default_handler);
    
    var io_req = io_uring.IoRequest{ .stream_id = 0, .buf_ptr = undefined };
    
    // ============================================================
    // Phase 1: 完成第一个请求
    // ============================================================
    const stream_id_1: u64 = 3001;
    const body_len_1: u32 = 5;
    
    std.debug.print("\n=== Phase 1: 第一个请求 (stream_id={}) ===\n", .{stream_id_1});
    
    proto.begin_receive(stream_id_1, accepted_fd, router.default_handler, null);
    try testing.expect(proto.state == .HeaderRecv);
    
    // HeaderRecv
    proto.set_header_recv_buf(stream_id_1, body_len_1, 0);
    var fake_hdr1: [13]u8 align(64) = undefined;
    io_req = io_uring.IoRequest{ .stream_id = stream_id_1, .buf_ptr = &fake_hdr1 };
    proto.push_cqe_for_test(@intFromPtr(&io_req), 13);
    _ = proto.step();
    try testing.expect(proto.state == .BodyRecv);
    
    // BodyRecv
    var fake_body1: [5]u8 align(64) = undefined;
    io_req = io_uring.IoRequest{ .stream_id = stream_id_1, .buf_ptr = &fake_body1 };
    proto.push_cqe_for_test(@intFromPtr(&io_req), body_len_1);
    _ = proto.step();
    try testing.expect(proto.state == .BodyDone);
    
    // BodyDone -> SendDone
    _ = proto.step();
    try testing.expect(proto.state == .SendDone);
    
    // SendDone -> WaitRequest
    var fake_send1: [100]u8 align(64) = undefined;
    io_req = io_uring.IoRequest{ .stream_id = stream_id_1, .buf_ptr = &fake_send1 };
    proto.push_cqe_for_test(@intFromPtr(&io_req), 100);
    _ = proto.step();
    try testing.expect(proto.state == .WaitRequest);
    
    std.debug.print("✅ Phase 1 完成：WaitRequest\n", .{});
    
    // ============================================================
    // Phase 1.5: reset_state_for_next_request + 重置 CQ 状态
    // ============================================================
    proto.reset_state_for_next_request();
    proto.debug_reset_cq(); // 关键：重置 CQ 指针到一致状态
    try testing.expect(proto.state == .Idle);
    try testing.expect(proto.accepted_fd == accepted_fd);
    
    std.debug.print("✅ Phase 1.5 完成：fd={}, CQ reset\n", .{proto.accepted_fd});
    
    // ============================================================
    // Phase 2: 第二个请求 - 完整状态机验证
    // ============================================================
    const stream_id_2: u64 = 3002;
    const body_len_2: u32 = 8;
    
    std.debug.print("\n=== Phase 2: 第二个请求 (stream_id={}) ===\n", .{stream_id_2});
    
    // 开始第二个请求（复用同一个 accepted_fd）
    proto.begin_receive(stream_id_2, accepted_fd, router.default_handler, null);
    try testing.expect(proto.state == .HeaderRecv);
    try testing.expect(proto.accepted_fd == accepted_fd);
    
    std.debug.print("✅ Phase 2 begin_receive 成功：state={s}, fd={}\n", .{ @tagName(proto.state), proto.accepted_fd });
    
    // HeaderRecv
    proto.set_header_recv_buf(stream_id_2, body_len_2, 0);
    var fake_hdr2: [13]u8 align(64) = undefined;
    io_req = io_uring.IoRequest{ .stream_id = stream_id_2, .buf_ptr = &fake_hdr2 };
    proto.push_cqe_for_test(@intFromPtr(&io_req), 13);
    var state = proto.step();
    std.debug.print("Phase 2 after HeaderRecv: state={s}\n", .{@tagName(proto.state)});
    try testing.expect(proto.state == .BodyRecv);
    
    std.debug.print("✅ Phase 2 HeaderRecv 成功\n", .{});
    
    // BodyRecv
    var fake_body2: [8]u8 align(64) = undefined;
    io_req = io_uring.IoRequest{ .stream_id = stream_id_2, .buf_ptr = &fake_body2 };
    proto.push_cqe_for_test(@intFromPtr(&io_req), body_len_2);
    state = proto.step();
    std.debug.print("Phase 2 after BodyRecv: state={s}\n", .{@tagName(proto.state)});
    try testing.expect(proto.state == .BodyDone);
    
    std.debug.print("✅ Phase 2 BodyRecv 成功\n", .{});
    
    // BodyDone -> SendDone
    state = proto.step();
    std.debug.print("Phase 2 after BodyDone: state={s}\n", .{@tagName(proto.state)});
    try testing.expect(proto.state == .SendDone);
    
    std.debug.print("✅ Phase 2 BodyDone → SendDone 成功\n", .{});
    
    // SendDone -> WaitRequest
    var fake_send2: [100]u8 align(64) = undefined;
    io_req = io_uring.IoRequest{ .stream_id = stream_id_2, .buf_ptr = &fake_send2 };
    proto.push_cqe_for_test(@intFromPtr(&io_req), 100);
    state = proto.step();
    std.debug.print("Phase 2 after SendDone: state={s}\n", .{@tagName(state)});
    try testing.expect(state == .WaitRequest);
    try testing.expect(proto.state == .WaitRequest);
    
    std.debug.print("✅ Phase 2 SendDone → WaitRequest 成功\n", .{});
    std.debug.print("✅ Phase 2 完成：第二个请求进入 WaitRequest\n", .{});
    
    // ============================================================
    // Phase 3: 验证连接存活
    // ============================================================
    try testing.expect(proto.accepted_fd == accepted_fd); // fd 从未被关闭
    try testing.expect(proto.state == .WaitRequest); // 第二个请求完成
    try testing.expect(window.access_header(stream_id_2) != null); // 第二个请求的槽位存在
    try testing.expect(window.access_header(stream_id_1) == null); // 第一个请求的槽位已释放
    
    std.debug.print("✅ Phase 3 验证通过：连接存活、fd={}\n", .{proto.accepted_fd});
    
    // 清理
    proto.reset();
    
    std.debug.print("\n✅ P33 测试全部通过！Phase 1 + Phase 2 双请求完整生命周期验证成功！\n", .{});
}
