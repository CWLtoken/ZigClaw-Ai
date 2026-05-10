// src/main.zig
// ZigClaw HTTP 服务器启动器 - 阶段27: 多实例部署支持
const debug = @import("std").debug;
const fmt = @import("std").fmt;
const log = @import("std").log;
const mem = @import("std").mem;
const posix = @import("std").posix;
const process = @import("std").process;
const io_uring = @import("io_uring.zig");
const http_server = @import("http_server.zig");

// 全局服务器指针（用于信号处理）
var g_server: ?*http_server.HttpServer = null;

// SIGINT 信号处理函数
fn sigint_handler(sig: i32, info: *posix.siginfo_t, ucontext: ?*anyopaque) callconv(.C) void {
    _ = sig;
    _ = info;
    _ = ucontext;
    
    debug.print("\n收到 SIGINT，准备优雅关闭...\n", .{});
    
    if (g_server) |server| {
        server.shutdown();
    }
}

pub fn main() !void {
    const log = std.log;
    log.info("启动 ZigClaw HTTP 服务器（阶段27 - 多实例部署支持）...", .{});
    
    // 解析命令行参数
    var port: u16 = 8080; // 默认端口
    var args = process.args();
    
    // 跳过程序名
    _ = args.next();
    
    while (args.next()) |arg| {
        if (mem.eql(u8, arg, "--port")) {
            if (args.next()) |port_str| {
                port = fmt.parseInt(u16, port_str, 10) catch {
                    debug.print("错误：无效的端口号 '{s}'\n", .{port_str});
                    process.exit(1);
                };
            } else {
                debug.print("错误：--port 需要指定端口号\n", .{});
                process.exit(1);
            }
        } else if (mem.eql(u8, arg, "--help")) {
            debug.print("用法: zigclaw [--port PORT]\n", .{});
            debug.print("  --port PORT  指定监听端口（默认: 8080）\n", .{});
            return;
        }
    }
    
    debug.print("使用端口: {d}\n", .{port});
    
    // 1. 初始化服务器指标
    var metrics = http_server.ServerMetrics.init();
    
    // 2. 初始化 HTTP 服务器（传入端口参数）
    var server = try http_server.HttpServer.init(&metrics, port);
    defer server.deinit();
    
    // 3. 设置全局指针（供信号处理函数使用）
    g_server = &server;
    
    // 4. 设置 SIGINT 信号处理
    var sa = posix.SigAction{
        .handler = .{ .handler = sigint_handler },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    try posix.sigaction(posix.SIG.INT, &sa, null);
    
    debug.print("按 Ctrl+C 优雅关闭服务器\n", .{});
    
    // 5. 运行服务器主循环（直到收到 SIGINT）
    server.run() catch |err| {
        debug.print("服务器异常退出: {}\n", .{err});
        return err;
    };
    
    debug.print("服务器已关闭\n", .{});
}
