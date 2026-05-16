// src/main.zig
// ZigClaw HTTP 服务器启动器 - 阶段28: 军规构建
// 存储层集成：HeatPool 初始化 + SSD 快照恢复 + 优雅退出保存
const std = @import("std");
const debug = std.debug;
const log = std.log;
const mem = std.mem;
const fmt = std.fmt;
const linux = std.os.linux;
const io_uring = @import("io_uring.zig");
const http_server = @import("http_server.zig");
const heat_pool = @import("heat_pool.zig");
const heat_snap = @import("heat_snap.zig");

// ============================================================================
// 全局状态
// ============================================================================

/// 全局服务器指针
var g_server: ?*http_server.HttpServer = null;

/// 热度池（全局单例）
pub var g_heat_pool: heat_pool.HeatPool = undefined;

/// 快照版本号（0/1 交替）
pub var g_snap_version: u32 = 0;

// ============================================================================
// 端口配置
// ============================================================================

/// 从环境变量读取端口
fn getEnvPort(env_buf: []const u8, needle: []const u8, default_port: u16) u16 {
    var pos: usize = 0;
    while (pos + needle.len < env_buf.len) {
        if (mem.eql(u8, env_buf[pos..pos+needle.len], needle)) {
            const val_start = pos + needle.len;
            var val_end = val_start;
            while (val_end < env_buf.len and env_buf[val_end] != 0) {
                val_end += 1;
            }
            if (val_end > val_start) {
                return fmt.parseInt(u16, env_buf[val_start..val_end], 10) catch default_port;
            }
        }
        while (pos < env_buf.len and env_buf[pos] != 0) {
            pos += 1;
        }
        pos += 1;
    }
    return default_port;
}

fn readEnviron() []const u8 {
    const fd = io_uring.Syscall.openat(
        @as(i32, -100),
        "/proc/self/environ",
        io_uring.Syscall.O_RDONLY,
        0,
    ) catch return "";
    defer io_uring.Syscall.close(@intCast(fd));

    var buf: [4096]u8 = undefined;
    const n = io_uring.read(fd, &buf, buf.len) catch return "";
    if (n == 0) return "";
    return buf[0..n];
}

// ============================================================================
// 存储层初始化
// ============================================================================

/// 初始化存储层：尝试从 SSD 恢复热度池
fn initStorage() void {
    g_heat_pool = heat_pool.HeatPool.init();
    g_snap_version = 0;

    heat_snap.loadHeatPool(&g_heat_pool) catch |err| {
        log.info("无快照或快照损坏，初始化全新热度池: {s}", .{@errorName(err)});
        return;
    };
    log.info("热度池已从 SSD 快照恢复", .{});
}

/// 保存快照（退出时调用）
fn saveStorage() void {
    heat_snap.saveHeatPool(&g_heat_pool, &g_snap_version);
    log.info("热度池快照已保存 (version={d})", .{g_snap_version});
}

// ============================================================================
// 主函数
// ============================================================================

pub fn main() !void {
    log.info("启动 ZigClaw HTTP 服务器...", .{});

    // 读取环境变量
    const env_buf = readEnviron();

    // 端口配置
    const port = getEnvPort(env_buf, "ZIGCLAW_PORT=", 8080);
    if (port == 8080) {
        log.info("使用默认端口 8080（可通过 ZIGCLAW_PORT 环境变量修改）", .{});
    }

    // 调试/编排层端口
    const debug_port = getEnvPort(env_buf, "ZIGCLAW_DEBUG_PORT=", 0);
    if (debug_port != 0) {
        log.info("调试端口: {d}", .{debug_port});
    }

    // 初始化存储层（SSD 快照恢复）
    initStorage();

    // 初始化服务器指标
    var metrics = http_server.ServerMetrics.init();

    // 初始化 HTTP 服务器
    var server = try http_server.HttpServer.init(&metrics, port);
    defer server.deinit();
    g_server = &server;

    log.info("监听端口 {d}", .{port});

    // 运行主循环
    server.run() catch |err| {
        debug.print("服务器异常退出: {}\n", .{err});
        saveStorage();
        return err;
    };

    // 正常退出时保存快照
    saveStorage();
    debug.print("服务器已关闭\n", .{});
}
