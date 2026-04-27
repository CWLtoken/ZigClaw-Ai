// src/server.zig
// ZigClaw V2.4 阶段 5 | 服务端网络脚手架
// 依赖：io_uring.zig（Syscall 块、SockAddrIn、Ring）
// 军规：本文件允许 const std = @import("std")（仅用于测试 print，非主干约束）

const std = @import("std");
const io_uring = @import("io_uring.zig");

/// 服务端上下文：持有监听 socket 和控制端 socket
pub const Server = struct {
    listen_fd: i32,
    control_fd: i32,
    port: u16,

    /// 初始化服务端：socket → bind → listen
    pub fn init(ring: *io_uring.Ring) !Server {
        _ = ring; // ZC-9-02: 消除未使用参数警告
        // 1. 创建监听 socket
        const listen_fd = try io_uring.Syscall.socket(
            io_uring.AF_INET,
            io_uring.SOCK_STREAM,
            0,
        );
        errdefer io_uring.Syscall.close(@intCast(listen_fd));

        // 2. 绑定 127.0.0.1:0（内核分配端口）
        var bind_addr = io_uring.SockAddrIn{
            .family = io_uring.AF_INET,
            .port = 0, // 内核分配随机端口
            .addr = io_uring.INADDR_LOOPBACK,
        };
        try io_uring.Syscall.bind(listen_fd, &bind_addr, @sizeOf(io_uring.SockAddrIn));

        // 3. 开始监听
        try io_uring.Syscall.listen(listen_fd, 1);

        // 4. 获取实际端口
        var actual_addr: io_uring.SockAddrIn = undefined;
        var addr_len: u32 = @sizeOf(io_uring.SockAddrIn);
        try io_uring.Syscall.getsockname(listen_fd, &actual_addr, &addr_len);
        const actual_port = io_uring.Syscall.htons(actual_addr.port); // ntohs

        return Server{
            .listen_fd = listen_fd,
            .control_fd = 0,
            .port = actual_port,
        };
    }

    /// 释放监听 socket
    pub fn deinit(self: *Server) void {
        io_uring.Syscall.close(@intCast(self.listen_fd));
    }
};
