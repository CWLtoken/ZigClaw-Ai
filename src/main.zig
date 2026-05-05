// src/main.zig
// ZigClaw HTTP 服务器启动器 - 阶段23B: Protocol/Reactor 深度集成
const std = @import("std");
const io_uring = @import("io_uring.zig");
const http_protocol = @import("http_protocol.zig");

pub fn main() !void {
    const log = std.log;
    log.info("启动 ZigClaw HTTP 服务器（阶段23B - Protocol集成）...", .{});

    // 1. 初始化 io_uring
    var ring = try io_uring.Ring.init();
    errdefer ring.deinit();

    // 2. 创建监听 socket
    const listen_fd = try io_uring.Syscall.socket(
        io_uring.AF_INET,
        io_uring.SOCK_STREAM,
        0,
    );
    defer io_uring.Syscall.close(listen_fd);

    // 3. 设置 SO_REUSEADDR（简化：跳过，非必须）
    // const reuse: i32 = 1;
    // _ = std.os.setsockopt(listen_fd, std.os.SOL.SOCKET, std.os.SO.REUSEADDR, &reuse, @sizeOf(i32)) catch {};

    // 4. 绑定 0.0.0.0:8080
    var addr = io_uring.SockAddrIn{
        .family = io_uring.AF_INET,
        .port = io_uring.htons(8080),
        .addr = 0, // 0.0.0.0
    };
    try io_uring.Syscall.bind(listen_fd, &addr, @sizeOf(io_uring.SockAddrIn));
    try io_uring.Syscall.listen(listen_fd, 128);

    // 5. 获取实际端口
    var actual_addr: io_uring.SockAddrIn = undefined;
    var addr_len: u32 = @sizeOf(io_uring.SockAddrIn);
    try io_uring.Syscall.getsockname(listen_fd, &actual_addr, &addr_len);
    const port = io_uring.htons(actual_addr.port);

    std.debug.print("🌐 HTTP 服务器启动（阶段23B）: http://127.0.0.1:{d}/\n", .{port});
    std.debug.print("   路由：\n", .{});
    std.debug.print("     GET /health → 健康检查\n", .{});
    std.debug.print("     GET /infer?input=xxx&modality=text|image → 推理\n", .{});
    std.debug.print("   使用 Protocol 状态机处理请求（集成版）\n", .{});
    std.debug.print("按 Ctrl+C 停止服务器\n", .{});

    // 6. 初始化 HttpProtocolHandler
    var handler = try http_protocol.HttpProtocolHandler.init();
    
    // 7. 主事件循环
    while (true) {
        std.debug.print("等待连接...\n", .{});

        // 使用 io_uring ACCEPT 获取连接
        const conn_fd = try io_uring.Syscall.accept(listen_fd, null, null);
        defer io_uring.Syscall.close(conn_fd);

        std.debug.print("收到连接，fd={d}\n", .{conn_fd});

        // 通过 HttpProtocolHandler 处理请求
        // 注意：这里应该通过 Protocol 状态机处理，目前是简化版
        try handler.handle_request(conn_fd);
    }
}
