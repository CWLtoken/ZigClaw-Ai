const std = @import("std");
const testing = std.testing;
const io_uring = @import("io_uring.zig");
const mem = std.mem;

test "Phase13: io_uring ACCEPT + SEND via TCP loopback" {
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
    const connect_fd_i32 = try io_uring.Syscall.socket(2, 1, 0);
    const connect_fd: u32 = @intCast(connect_fd_i32);
    defer io_uring.Syscall.close(@intCast(connect_fd));
    var server_addr = io_uring.SockAddrIn{
        .family = 2,
        .port = io_uring.Syscall.htons(actual_port),
        .addr = 0x0100007F,
    };
    try io_uring.Syscall.connect(connect_fd, &server_addr, @sizeOf(io_uring.SockAddrIn));

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

    // 8. submit SEND via io_uring
    const message = "HELLO";
    var send_buf: [16]u8 = undefined;
    @memcpy(send_buf[0..message.len], message[0..]);
    sq_tail = @atomicLoad(u32, ring.sq_tail, .acquire);
    const sqe_s = &ring.sq_entries[sq_tail & ring.sq_ring_mask];
    sqe_s.* = .{
        .opcode = @intFromEnum(io_uring.IOOp.Send),
        .flags = 0,
        .ioprio = 0,
        .fd = accepted_fd,
        .off = 0,
        .addr = @intFromPtr(&send_buf),
        .len = message.len,
        .__pad1 = 0,
        .user_data = 9002,
        .buf_index = 0,
        .personality = 0,
        .splice_fd_in = 0,
        .addr3 = 0,
        .__pad2 = 0,
    };
    ring.sq_array[sq_tail & ring.sq_ring_mask] = sq_tail & ring.sq_ring_mask;
    @atomicStore(u32, ring.sq_tail, sq_tail + 1, .release);
    const submitted_s = try io_uring.Syscall.enter(ring.fd, 1, 1, 0);
    try testing.expectEqual(@as(u32, 1), submitted_s);
    cq_head = @atomicLoad(u32, ring.cq_head, .acquire);
    const cqe_s = &ring.cqes[cq_head & ring.cq_ring_mask];
    try testing.expectEqual(@as(u64, 9002), cqe_s.user_data);
    try testing.expectEqual(@as(i32, message.len), cqe_s.res);
    @atomicStore(u32, ring.cq_head, cq_head + 1, .release);

    // 9. verify with blocking recv
    var recv_buf: [16]u8 = undefined;
    const received = try io_uring.Syscall.recv(connect_fd, &recv_buf, 16, 0);
    try testing.expectEqual(@as(i32, message.len), received);
    try testing.expectEqualSlices(u8, message, recv_buf[0..@intCast(received)]);
}
