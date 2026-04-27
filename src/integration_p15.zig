// src/integration_p15.zig
// ZigClaw V2.4 阶段 5 | Protocol 报头接收测试（真实网络）
// 目标：验证 Protocol 通过真实 io_uring RECV 接收 13 字节报头，状态机 HeaderRecv → BodyRecv

const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const core = @import("core.zig");
const storage = @import("storage.zig");
const io_uring = @import("io_uring.zig");
const reactor = @import("reactor.zig");
const protocol = @import("protocol.zig");
const server_mod = @import("server.zig");

const TEST_STREAM_ID: u64 = 42;

test "Phase15: Protocol receives 13-byte header via io_uring RECV" {
    // ===========================================================
    // 阶段 1：启动服务器
    // ===========================================================
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    var srv = try server_mod.Server.init(&ring);
    defer srv.deinit();

    // ===========================================================
    // 阶段 2：客户端连接 + 发送报头
    // ===========================================================
    const client_fd = try io_uring.Syscall.socket(
        io_uring.AF_INET,
        io_uring.SOCK_STREAM,
        0,
    );
    defer io_uring.Syscall.close(@intCast(client_fd));

    var srv_addr = io_uring.SockAddrIn{
        .family = io_uring.AF_INET,
        .port = io_uring.Syscall.htons(srv.port),
        .addr = io_uring.INADDR_LOOPBACK,
    };
    try io_uring.Syscall.connect(client_fd, &srv_addr, @sizeOf(io_uring.SockAddrIn));

    // 构造 13 字节报头（TokenStreamHeader 格式）
    var header_buf: [13]u8 = [_]u8{0} ** 13;
    mem.writeInt(u64, header_buf[0..8], TEST_STREAM_ID, .little);
    mem.writeInt(u32, header_buf[8..12], 4096, .little); // total_len = 4096
    header_buf[12] = 0; // op_code = 0

    // 直接使用 std.os.linux.sendto 绕过 Syscall.send 封装问题
    const linux = std.os.linux;
    const sent = linux.sendto(client_fd, &header_buf, 13, 0, null, 0);
    if (sent != 13) {
        std.debug.print("sendto failed: {}\n", .{sent});
        return error.SendFailed;
    }

    // ===========================================================
    // 阶段 3：io_uring ACCEPT（接收客户端连接）
    // ===========================================================
    var client_addr: io_uring.SockAddrIn = undefined;
    var client_addr_len: u32 = @sizeOf(io_uring.SockAddrIn);

    var sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    const accept_idx = sq_tail & ring.sq_ring_mask;
    ring.sq_entries[accept_idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.Accept),
        .flags = 0,
        .ioprio = 0,
        .fd = srv.listen_fd,
        .off = @intFromPtr(&client_addr_len),    // addr2 = addrlen 指针
        .addr = @intFromPtr(&client_addr),        // addr = sockaddr 指针
        .len = 0,
        .__pad1 = 0,
        .user_data = 1001,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[accept_idx] = @intCast(accept_idx);
    @atomicStore(u32, ring.sq_tail, sq_tail + 1, .release);

    const accept_submitted = try io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    try testing.expectEqual(@as(u32, 1), accept_submitted);

    var cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const accept_cqe = &ring.cqes[cq_head & ring.cq_ring_mask];
    try testing.expectEqual(@as(u64, 1001), accept_cqe.user_data);
    try testing.expect(accept_cqe.res >= 0);
    const accepted_fd: i32 = @intCast(accept_cqe.res);
    defer io_uring.Syscall.close(@intCast(accepted_fd));
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    // ===========================================================
    // 阶段 4：io_uring RECV（通过 accepted_fd 接收报头数据）
    // ===========================================================
    var recv_buf: [4096]u8 = undefined;
    var recv_iovec = io_uring.Iovec{
        .iov_base = @ptrCast(&recv_buf),
        .iov_len = 13,
    };

    sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    const recv_idx = sq_tail & ring.sq_ring_mask;
    ring.sq_entries[recv_idx] = .{
        .opcode = @intFromEnum(io_uring.IOOp.ReadV),
        .flags = 0,
        .ioprio = 0,
        .fd = accepted_fd,
        .off = 0,
        .addr = @intFromPtr(&recv_iovec),
        .len = 1, // 1 个 iovec
        .__pad1 = 0,
        .user_data = 2001,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[recv_idx] = @intCast(recv_idx);
    @atomicStore(u32, ring.sq_tail, sq_tail + 1, .release);

    const recv_submitted = try io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    try testing.expectEqual(@as(u32, 1), recv_submitted);

    cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const recv_cqe = &ring.cqes[cq_head & ring.cq_ring_mask];
    try testing.expectEqual(@as(u64, 2001), recv_cqe.user_data);
    try testing.expectEqual(@as(i32, 13), recv_cqe.res); // 接收到 13 字节
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    // ===========================================================
    // 阶段 5：验证接收到的报头内容
    // ===========================================================
    const received_stream_id = mem.readInt(u64, recv_buf[0..8], .little);
    const received_total_len = mem.readInt(u32, recv_buf[8..12], .little);
    try testing.expectEqual(@as(u64, TEST_STREAM_ID), received_stream_id);
    try testing.expectEqual(@as(u32, 4096), received_total_len);
    try testing.expectEqual(@as(u8, 0), recv_buf[12]); // op_code = 0

    // ===========================================================
    // 阶段 6：Protocol 状态机验证（HeaderRecv → BodyRecv）
    // ===========================================================
    var window = storage.StreamWindow.init();
    var test_body_pool = storage.BodyBufferPool.init();

    // 将接收到的报头写入 StreamWindow（模拟协议栈注册报头）
    var hdr = core.TokenStreamHeader.init();
    @memcpy(&hdr.data, recv_buf[0..13]);
    window.push_header(hdr);

    var proto = try protocol.Protocol.init_with_ring(&window, &test_body_pool, &ring);

    // 初始状态：Idle
    try testing.expectEqual(protocol.State.Idle, proto.state);

    // 开始接收
    proto.begin_receive(TEST_STREAM_ID);

    // 构造 IoRequest（模拟 Reactor.poll() 解码 user_data 后的结果）
    var io_req = io_uring.IoRequest{
        .stream_id = TEST_STREAM_ID,
        .buf_ptr = @as(?*anyopaque, @ptrCast(&recv_buf)),
    };

    // 手动推入 CQE（模拟 io_uring 完成）
    // 注意：Reactor.poll() 从 cq_head 读取，所以我们在 cq_head 位置写入
    const cq_head_loc = @atomicLoad(u32, ring.cq_head, .acquire);
    const cqe_idx = cq_head_loc & ring.cq_ring_mask;
    const fake_cqe = &ring.cqes[cqe_idx];
    fake_cqe.* = .{
        .user_data = @intFromPtr(&io_req),
        .res = 13,
        .flags = 0,
    };
    // 先设置 buf_ptr，再推进 cq_tail，确保 Reactor.poll() 读到时 buf_ptr 已就绪
    io_req.buf_ptr = @as(?*anyopaque, @ptrCast(&recv_buf));
    // 模拟内核行为：推进 cq_tail，让 Reactor.poll() 检测到 CQ 非空
    @atomicStore(u32, ring.cq_tail, cq_head_loc + 1, .release);

    // 调用 Protocol.step() 进行状态转移
    const state = proto.step();
    try testing.expectEqual(protocol.State.BodyRecv, state);
}
