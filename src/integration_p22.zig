// src/integration_p22.zig
// ZigClaw V2.4 Phase12 | 压力测试 | StreamWindow 64槽位填满
const std = @import("std");
const router = @import("router.zig");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const protocol = @import("protocol.zig");

test "P22-S1: StreamWindow 64槽位填满" {
    var window = storage.StreamWindow.init();
    try testing.expectEqual(@as(u64, 0), window.len);

    // 添加64个 header
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var header = core.TokenStreamHeader.init();
        mem.writeInt(u64, header.data[0..8], 1000 + i, .little);
        mem.writeInt(u32, header.data[8..12], 100, .little);
        window.push_header(header);
        try testing.expectEqual(@as(u64, i + 1), window.len);
    }
    try testing.expectEqual(@as(u64, 64), window.len);

    // 尝试添加第65个（应该被静默丢弃）
    var header65 = core.TokenStreamHeader.init();
    mem.writeInt(u64, header65.data[0..8], 1064, .little);
    window.push_header(header65);
    try testing.expectEqual(@as(u64, 64), window.len); // 仍然是64
}

test "P22-S2: 验证所有64个槽位可访问并释放" {
    var window = storage.StreamWindow.init();

    // 添加64个 header
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        var header = core.TokenStreamHeader.init();
        mem.writeInt(u64, header.data[0..8], 2000 + i, .little);
        window.push_header(header);
    }

    // 验证所有64个槽位可访问
    i = 0;
    while (i < 64) : (i += 1) {
        const stream_id: u64 = 2000 + i;
        const h = window.access_header(stream_id);
        try testing.expect(h != null);
        const id = mem.readInt(u64, h.?.data[0..8], .little);
        try testing.expectEqual(stream_id, id);
    }

    // 释放所有槽位并验证
    i = 0;
    while (i < 64) : (i += 1) {
        window.release_header(2000 + i);
        try testing.expectEqual(@as(u64, 64 - i - 1), window.len);
    }
    try testing.expectEqual(@as(u64, 0), window.len);
}

// 辅助：写入 fake CQE（模拟内核完成）
fn push_cqe(ring: *io_uring.Ring, user_data: u64, res: i32) void {
    const tail = @atomicLoad(u32, ring.cq_tail, .acquire);
    const idx = tail & ring.cq_ring_mask;
    ring.cqes[idx] = .{ .user_data = user_data, .res = res, .flags = 0 };
    @atomicStore(u32, ring.cq_tail, tail + 1, .release);
}

test "P22-S3: 64槽位 SendDone→WaitRequest 及超时回收" {
    // 初始化
    var window = storage.StreamWindow.init();
    var body_pool = storage.BodyBufferPool.init();
    
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);
    
    // 测试单个流完整的状态转换
    const stream_id: u64 = 3001;
    const body_len: u32 = 5;
    
    var proto = try protocol.Protocol.init_with_ring(&window, &body_pool, &ring, router.default_handler);
    
    // 开始接收
    proto.begin_receive(stream_id, 100, router.default_handler, null);
    try testing.expect(proto.state == .HeaderRecv);
    
    // === 步骤1: 处理 HeaderRecv ===
    // 设置 header_recv_buf（模拟内核完成RECV，数据已写入缓冲区）
    proto.set_header_recv_buf(stream_id, body_len, 0);
    
    // 注入 HeaderRecv CQE
    var fake_hdr: [13]u8 align(64) = undefined;
    var io_req = io_uring.IoRequest{ .stream_id = stream_id, .buf_ptr = &fake_hdr };
    push_cqe(&ring, @intFromPtr(&io_req), 13);
    
    var state = proto.step();
    // 应该转到 BodyRecv
    try testing.expect(proto.state == .BodyRecv);
    
    // 验证 header 已经被 Protocol push 到 window 中
    try testing.expect(window.access_header(stream_id) != null);
    try testing.expectEqual(@as(u64, 1), window.len);
    
    // === 步骤2: 处理 BodyRecv ===
    var fake_body: [5]u8 align(64) = undefined;
    io_req.buf_ptr = &fake_body;
    push_cqe(&ring, @intFromPtr(&io_req), body_len);
    
    state = proto.step();
    // BodyRecv完成后应该转到 BodyDone
    try testing.expect(proto.state == .BodyDone);
    
    // === 步骤3: 处理 BodyDone（会调用handler，提交SEND，转到SendDone） ===
    state = proto.step();
    // 应该转到 SendDone
    try testing.expect(proto.state == .SendDone);
    
    // === 步骤4: 处理 SendDone（立即转到 WaitRequest） ===
    // 注入SEND的CQE
    var fake_send: [100]u8 align(64) = undefined;
    io_req.buf_ptr = &fake_send;
    push_cqe(&ring, @intFromPtr(&io_req), 100);
    
    state = proto.step();
    // SendDone处理应该转到 WaitRequest
    try testing.expect(state == .WaitRequest);
    try testing.expect(proto.state == .WaitRequest);
    
    // 验证 accepted_fd 保持（连接未关闭）
    try testing.expectEqual(@as(i32, 100), proto.accepted_fd);
    
    // 验证槽位仍在 window 中
    try testing.expect(window.access_header(stream_id) != null);
    try testing.expectEqual(@as(u64, 1), window.len);
    
    // === 测试超时回收：调用 reset_state_for_next_request ===
    proto.reset_state_for_next_request();
    try testing.expectEqual(protocol.State.Idle, proto.state);
    try testing.expectEqual(@as(i32, 100), proto.accepted_fd); // fd 保持
    
    // 槽位应该被释放
    try testing.expect(window.access_header(stream_id) == null);
    
    // 验证 window 为空
    try testing.expectEqual(@as(u64, 0), window.len);
    
    // 清理
    proto.reset();
}
