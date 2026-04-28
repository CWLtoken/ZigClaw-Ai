// src/integration_p16.zig
// ZigClaw V2.4 阶段 5 | P16: Protocol 主动 RECV 完整请求响应循环
// 目标：验证 Protocol 在 HeaderRecv/BodyRecv 状态主动提交 RECV，实现全链路闭环
// 架构师裁决：使用项目已有的 io_uring.Syscall 封装，不依赖 std.os.*

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");
const protocol = @import("protocol.zig");

const TEST_STREAM_ID: u64 = 42;
const TEST_BODY_LEN: u32 = 32;

test "Phase16: Protocol active RECV full request-response cycle" {
    // ===========================================================
    // 阶段 1：创建 Protocol
    // ===========================================================
    var window = storage.StreamWindow.init();
    var test_body_pool = storage.BodyBufferPool.init();
    var proto = try protocol.Protocol.init(&window, &test_body_pool);

    // 初始状态：Idle
    try testing.expectEqual(protocol.State.Idle, proto.state);

    // ===========================================================
    // 阶段 2：建立 TCP 连接（使用 io_uring.Syscall 封装）
    // ===========================================================
    // 创建监听 socket
    const listen_fd = try io_uring.Syscall.socket(io_uring.AF_INET, io_uring.SOCK_STREAM, 0);
    defer io_uring.Syscall.close(@intCast(listen_fd));

    // bind 到 127.0.0.1:0（端口 0 = 让内核分配）
    var saddr: io_uring.SockAddrIn = .{};
    saddr.family = 2; // AF_INET = 2，直接使用，不需要 htons
    saddr.port = 0; // 让内核分配端口
    saddr.addr = io_uring.INADDR_LOOPBACK; // 127.0.0.1
    try io_uring.Syscall.bind(listen_fd, &saddr, @sizeOf(io_uring.SockAddrIn));

    // listen
    try io_uring.Syscall.listen(listen_fd, 1);

    // 获取实际监听端口
    var getsockname_saddr: io_uring.SockAddrIn = .{};
    var addrlen: u32 = @sizeOf(io_uring.SockAddrIn);
    try io_uring.Syscall.getsockname(listen_fd, &getsockname_saddr, &addrlen);
    // getsockname_saddr.port 已经是网络字节序，直接使用

    // ===========================================================
    // 阶段 3：io_uring ACCEPT 获取 accepted_fd
    // ===========================================================
    const accept_ring = &proto.reactor.ring;

    // 准备客户端地址接收缓冲区
    var client_addr: io_uring.SockAddrIn = undefined;
    var client_addr_len: u32 = @sizeOf(io_uring.SockAddrIn);

    // 提交 ACCEPT SQE（按照 P14 的正确格式）
    const accept_sq_tail = @atomicLoad(u32, accept_ring.sq_tail, .acquire);
    const accept_idx = accept_sq_tail & io_uring.SQ_MASK;
    accept_ring.sq_entries[accept_idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.Accept),
        .flags = 0,
        .ioprio = 0,
        .fd = listen_fd,
        .off = @intFromPtr(&client_addr_len), // addrlen 指针
        .addr = @intFromPtr(&client_addr), // 客户端地址
        .len = 0, // 不是地址长度
        .__pad1 = 0,
        .user_data = 0xACE1, // 特殊 user_data 标记（ACCEPT）
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    accept_ring.sq_array[accept_idx] = accept_idx;
    @atomicStore(u32, accept_ring.sq_tail, accept_sq_tail + 1, .release);

    // 提交 ACCEPT SQE 到内核（不等待完成）
    _ = try proto.reactor.submit(1, 0);

    // 客户端连接（使用 Syscall.connect）
    const client_fd = try io_uring.Syscall.socket(io_uring.AF_INET, io_uring.SOCK_STREAM, 0);
    defer io_uring.Syscall.close(@intCast(client_fd));

    var client_saddr: io_uring.SockAddrIn = .{};
    client_saddr.family = 2; // AF_INET = 2
    client_saddr.port = getsockname_saddr.port; // 直接使用网络字节序的端口
    client_saddr.addr = io_uring.INADDR_LOOPBACK;
    try io_uring.Syscall.connect(client_fd, &client_saddr, @sizeOf(io_uring.SockAddrIn));

    // 等待 ACCEPT 完成
    _ = try proto.reactor.submit(0, 1); // 等待至少 1 个 CQE
    const accept_cqe = accept_ring.cqes[0];
    try testing.expectEqual(@as(u64, 0xACE1), accept_cqe.user_data);
    const accepted_fd: i32 = @intCast(accept_cqe.res);
    try testing.expect(accepted_fd > 0);

    // 推进 cq_head，让内核知道这个 CQE 已消费
    @atomicStore(u32, accept_ring.cq_head, 1, .release);

    // ===========================================================
    // 阶段 4：Protocol 开始接收（传入 accepted_fd）
    // ===========================================================
    proto.begin_receive(TEST_STREAM_ID, accepted_fd);
    try testing.expectEqual(protocol.State.HeaderRecv, proto.state);

    // ===========================================================
    // 阶段 5：Protocol.step() 提交 RECV 接收报头
    // ===========================================================
    // 第一次调用 step()：poll() 返回 Idle，提交 RECV，返回 HeaderRecv
    const state0 = proto.step();
    try testing.expectEqual(protocol.State.HeaderRecv, state0);

    // ===========================================================
    // 阶段 6：客户端发送 13 字节报头
    // ===========================================================
    var header = core.TokenStreamHeader.init();
    mem.writeInt(u64, header.data[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, header.data[8..12], TEST_BODY_LEN, .little); // total_len = 32
    header.data[12] = 0; // op_code = 0
    // 军令3：验证第一步 send 是否成功
    const sent_header = try io_uring.Syscall.send(@intCast(client_fd), &header.data, 13, 0);
    try testing.expectEqual(@as(i32, 13), sent_header);

    // ===========================================================
    // 阶段 7：等待 RECV 完成，然后 step() 处理 IoComplete
    // ===========================================================
    // 等待 RECV 完成（报头）
    _ = try proto.reactor.submit(0, 1);
    // 处理 IoComplete，转移到 BodyRecv
    const state1 = proto.step();
    try testing.expectEqual(protocol.State.BodyRecv, state1);
    
    // 再次调用 step()，触发 BodyRecv 的 Idle 分支，提交 body RECV
    _ = proto.step();

    // ===========================================================
    // 阶段 8：客户端发送 32 字节 body
    // ===========================================================
    var body: [TEST_BODY_LEN]u8 = undefined;
    @memset(&body, 0xAB);
    _ = io_uring.Syscall.send(@intCast(client_fd), &body, TEST_BODY_LEN, 0) catch |err| {
        return err;
    };

    // ===========================================================
    // 阶段 9：等待 RECV 完成，然后 step() 处理 IoComplete
    // ===========================================================
    // 等待 RECV 完成
    _ = try proto.reactor.submit(0, 1);
    // 现在 step() 应该处理 IoComplete，转移到 BodyDone
    const state2 = proto.step();
    try testing.expectEqual(protocol.State.BodyDone, state2);

    // ===========================================================
    // 阶段 10：验证数据是否正确接收
    // ===========================================================
    const final_header = window.access_header(TEST_STREAM_ID).?;
    const final_len = mem.readInt(u32, final_header.data[8..12], .little);
    try testing.expectEqual(@as(u32, 0), final_len); // remaining = 0

    // 验证 body 内容
    const body_slice = test_body_pool.get_read_slice(TEST_STREAM_ID, TEST_BODY_LEN);
    try testing.expectEqual(@as(u8, 0xAB), body_slice[0]);
    try testing.expectEqual(@as(u8, 0xAB), body_slice[TEST_BODY_LEN - 1]);

    // 关闭 accepted_fd
    io_uring.Syscall.close(@intCast(accepted_fd));
}
