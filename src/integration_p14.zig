const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");
const mem = std.mem;

test "Phase14: io_uring RECV + SEND full bidirectional loop" {
    var ring = try io_uring.Ring.init();
    defer io_uring.Syscall.close(ring.fd);

    // 1. create listen socket
    const listen_fd = try io_uring.Syscall.socket(2, 1, 0);
    defer io_uring.Syscall.close(@intCast(listen_fd));

    // 2. bind 127.0.0.1:0
    var bind_addr = io_uring.SockAddrIn{
        .family = 2,
        .port = 0,
        .addr = 0x0100007F,
    };
    try io_uring.Syscall.bind(listen_fd, &bind_addr, @sizeOf(io_uring.SockAddrIn));

    // 3. listen
    try io_uring.Syscall.listen(listen_fd, 1);

    // 4. getsockname to get actual port
    var actual_addr: io_uring.SockAddrIn = undefined;
    var addr_len: u32 = @sizeOf(io_uring.SockAddrIn);
    try io_uring.Syscall.getsockname(listen_fd, &actual_addr, &addr_len);
    const actual_port = io_uring.Syscall.htons(actual_addr.port);

    // 5. submit ACCEPT via io_uring
    var client_addr: io_uring.SockAddrIn = undefined;
    var client_addr_len: u32 = @sizeOf(io_uring.SockAddrIn);
    var sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    const sqe_a = &ring.sq_entries[sq_tail & ring.sq_ring_mask];
    sqe_a.* = .{
        .opcode = @intFromEnum(io_uring.IOOp.Accept),
        .flags = 0,
        .ioprio = 0,
        .fd = listen_fd,
        .off = @intFromPtr(&client_addr_len),  // addr2 union: addrlen pointer
        .addr = @intFromPtr(&client_addr),
        .len = 0,
        .__pad1 = 0,  // accept_flags = 0
        .user_data = 9001,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[sq_tail & ring.sq_ring_mask] = sq_tail & ring.sq_ring_mask;
    @atomicStore(u32, ring.sq_tail, sq_tail + 1, .release);

    // 6. connect (blocking, for test simplicity)
    const connect_fd = try io_uring.Syscall.socket(2, 1, 0);
    const connect_fd_u32: u32 = @intCast(connect_fd);
    defer io_uring.Syscall.close(connect_fd_u32);
    defer io_uring.Syscall.close(@intCast(connect_fd));
    var server_addr = io_uring.SockAddrIn{
        .family = 2,
        .port = io_uring.Syscall.htons(actual_port),
        .addr = 0x0100007F,
    };
    try io_uring.Syscall.connect(connect_fd_u32, &server_addr, @sizeOf(io_uring.SockAddrIn));

    // 7. wait for ACCEPT completion
    const submitted_a = try io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    try testing.expectEqual(@as(u32, 1), submitted_a);
    var cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cqe_a = &ring.cqes[cq_head & ring.cq_ring_mask];
    try testing.expectEqual(@as(u64, 9001), cqe_a.user_data);
    try testing.expect(cqe_a.res >= 0);
    const accepted_fd: i32 = @intCast(cqe_a.res);
    defer io_uring.Syscall.close(@intCast(accepted_fd));
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    // 8. client sends "PING"
    const ping_msg = "PING";
    const sent = try io_uring.Syscall.send(connect_fd_u32, ping_msg.ptr, ping_msg.len, 0);
    try testing.expectEqual(@as(i32, ping_msg.len), sent);

    // 9. submit RECV via io_uring to receive "PING"
    var recv_buf: [16]u8 = undefined;
    sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    const sqe_r = &ring.sq_entries[sq_tail & ring.sq_ring_mask];
    sqe_r.* = .{
        .opcode = @intFromEnum(io_uring.IOOp.Recv),
        .flags = 0,
        .ioprio = 0,
        .fd = accepted_fd,
        .off = 0,
        .addr = @intFromPtr(&recv_buf),
        .len = recv_buf.len,
        .__pad1 = 0,  // flags = 0 (blocking recv)
        .user_data = 9002,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[sq_tail & ring.sq_ring_mask] = sq_tail & ring.sq_ring_mask;
    @atomicStore(u32, ring.sq_tail, sq_tail + 1, .release);

    // 10. wait for RECV completion
    const submitted_r = try io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    try testing.expectEqual(@as(u32, 1), submitted_r);
    cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cqe_r = &ring.cqes[cq_head & ring.cq_ring_mask];
    try testing.expectEqual(@as(u64, 9002), cqe_r.user_data);
    try testing.expectEqual(@as(i32, ping_msg.len), cqe_r.res);
    try testing.expectEqualSlices(u8, ping_msg, recv_buf[0..@intCast(cqe_r.res)]);
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    // 11. submit SEND via io_uring to send "PONG"
    const pong_msg = "PONG";
    var send_buf: [16]u8 = undefined;
    @memcpy(send_buf[0..pong_msg.len], pong_msg[0..]);
    sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    const sqe_s = &ring.sq_entries[sq_tail & ring.sq_ring_mask];
    sqe_s.* = .{
        .opcode = @intFromEnum(io_uring.IOOp.Send),
        .flags = 0,
        .ioprio = 0,
        .fd = accepted_fd,
        .off = 0,
        .addr = @intFromPtr(&send_buf),
        .len = pong_msg.len,
        .__pad1 = 0,
        .user_data = 9003,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[sq_tail & ring.sq_ring_mask] = sq_tail & ring.sq_ring_mask;
    @atomicStore(u32, ring.sq_tail, sq_tail + 1, .release);

    // 12. wait for SEND completion
    const submitted_s = try io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    try testing.expectEqual(@as(u32, 1), submitted_s);
    cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cqe_s = &ring.cqes[cq_head & ring.cq_ring_mask];
    try testing.expectEqual(@as(u64, 9003), cqe_s.user_data);
    try testing.expectEqual(@as(i32, pong_msg.len), cqe_s.res);
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    // 13. client recv "PONG" to verify
    var client_recv_buf: [16]u8 = undefined;
    const received = try io_uring.Syscall.recv(connect_fd_u32, &client_recv_buf, client_recv_buf.len, 0);
    try testing.expectEqual(@as(i32, pong_msg.len), received);
    try testing.expectEqualSlices(u8, pong_msg, client_recv_buf[0..@intCast(received)]);
}
