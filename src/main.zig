// src/main.zig
// ZigClaw HTTP 服务器启动器 - 阶段28: 军规构建
const std = @import("std");
const debug = std.debug;
const log = std.log;
const mem = std.mem;
const fmt = std.fmt;
const io_uring = @import("io_uring.zig");
const http_server = @import("http_server.zig");

/// 从环境变量读取端口（Zig 0.16 无 std.os.getenv，使用 /proc/self/environ）
fn getPort() u16 {
    const fd = io_uring.Syscall.openat(
        @as(i32, -100),
        "/proc/self/environ",
        io_uring.Syscall.O_RDONLY,
        0,
    ) catch return 8080;
    defer io_uring.Syscall.close(@intCast(fd));

    var buf: [4096]u8 = undefined;
    const n = io_uring.read(fd, &buf, buf.len) catch return 8080;
    if (n == 0) return 8080;

    const needle = "ZIGCLAW_PORT=";
    const env_buf = buf[0..n];
    var pos: usize = 0;
    while (pos + needle.len < env_buf.len) {
        if (mem.eql(u8, env_buf[pos..pos+needle.len], needle)) {
            const val_start = pos + needle.len;
            var val_end = val_start;
            while (val_end < env_buf.len and env_buf[val_end] != 0) {
                val_end += 1;
            }
            if (val_end > val_start) {
                return fmt.parseInt(u16, env_buf[val_start..val_end], 10) catch 8080;
            }
        }
        while (pos < env_buf.len and env_buf[pos] != 0) {
            pos += 1;
        }
        pos += 1;
    }
    return 8080;
}

// 全局服务器指针（原子操作保证信号处理安全）
var g_server: ?*http_server.HttpServer = null;

pub fn main() !void {
    log.info("启动 ZigClaw HTTP 服务器...", .{});

    // 从环境变量读取端口（默认 8080）
    const port = getPort();
    if (port == 8080) {
        log.info("使用默认端口 8080（可通过 ZIGCLAW_PORT 环境变量修改）", .{});
    }

    // 1. 初始化服务器指标
    var metrics = http_server.ServerMetrics.init();

    // 2. 初始化 HTTP 服务器
    var server = try http_server.HttpServer.init(&metrics, port);
    defer server.deinit();
    g_server = &server;

    log.info("监听端口 {d}", .{port});

    // 3. 运行主循环
    server.run() catch |err| {
        debug.print("服务器异常退出: {}\n", .{err});
        return err;
    };
    debug.print("服务器已关闭\n", .{});
}