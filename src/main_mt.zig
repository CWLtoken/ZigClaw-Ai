// src/main_mt.zig
// ZigClaw 多线程 HTTP 服务器入口
// 使用方式: zig build run -Dmt=true
//
// 架构：
//   - 默认 4 个 worker 线程（可通过 ZIGCLAW_WORKERS 环境变量调整）
//   - 每线程独立 io_uring ring + Reactor
//   - SO_REUSEPORT 内核级负载均衡

const log = @import("std").log;
const fmt = @import("std").fmt;
const io_uring = @import("io_uring.zig");
const http_server_mt = @import("http_server_mt.zig");

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
        if (@import("std").mem.eql(u8, env_buf[pos..pos+needle.len], needle)) {
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

fn getNumWorkers() u32 {
    const fd = io_uring.Syscall.openat(
        @as(i32, -100),
        "/proc/self/environ",
        io_uring.Syscall.O_RDONLY,
        0,
    ) catch return 4;
    defer io_uring.Syscall.close(@intCast(fd));

    var buf: [4096]u8 = undefined;
    const n = io_uring.read(fd, &buf, buf.len) catch return 4;
    if (n == 0) return 4;

    const needle = "ZIGCLAW_WORKERS=";
    const env_buf = buf[0..n];
    var pos: usize = 0;
    while (pos + needle.len < env_buf.len) {
        if (@import("std").mem.eql(u8, env_buf[pos..pos+needle.len], needle)) {
            const val_start = pos + needle.len;
            var val_end = val_start;
            while (val_end < env_buf.len and env_buf[val_end] != 0) {
                val_end += 1;
            }
            if (val_end > val_start) {
                return fmt.parseInt(u32, env_buf[val_start..val_end], 10) catch 4;
            }
        }
        while (pos < env_buf.len and env_buf[pos] != 0) {
            pos += 1;
        }
        pos += 1;
    }
    return 4;
}

pub fn main() !void {
    log.info("启动 ZigClaw 多线程 HTTP 服务器...", .{});

    const port = getPort();
    const num_workers = getNumWorkers();

    log.info("端口: {d}, Worker 数: {d}", .{ port, num_workers });

    var server = try http_server_mt.HttpServerMT.init(port, num_workers);
    defer server.deinit();

    try server.start();

    log.info("所有 Worker 已启动，等待连接...", .{});

    // 等待所有 worker 线程（阻塞主线程）
    server.join();

    log.info("服务器已关闭", .{});
}
