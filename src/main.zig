// src/main.zig
// ZigClaw HTTP 服务器启动器 - 阶段28: 军规构建
const debug = @import("std").debug;
const log = @import("std").log;
const mem = @import("std").mem;
const io_uring = @import("io_uring.zig");
const http_server = @import("http_server.zig");

// 全局服务器指针（原子操作保证信号处理安全）
var g_server: ?*http_server.HttpServer = null;

pub fn main() !void {
    log.info("启动 ZigClaw HTTP 服务器...", .{});

    const port: u16 = 8080; // TODO: 支持 ZIGCLAW_PORT 环境变量

    // 1. 初始化服务器指标
    var metrics = http_server.ServerMetrics.init();

    // 2. 初始化 HTTP 服务器
    var server = try http_server.HttpServer.init(&metrics, port);
    defer server.deinit();
    g_server = &server;

    debug.print("监听从端口 {d} （TODO: 支持 --port 和 ZIGCLAW_PORT）\n", .{port});

    // 3. 运行主循环
    server.run() catch |err| {
        debug.print("服务器异常退出: {}\n", .{err});
        return err;
    };
    debug.print("服务器已关闭\n", .{});
}