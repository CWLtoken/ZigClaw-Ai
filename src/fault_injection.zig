// src/fault_injection.zig
// 错误注入测试模块 — 用于模拟 io_uring 初始化失败、EAGAIN、磁盘满、连接中断等故障
// 设计原则：
//   - 零堆分配：所有操作在栈上完成
//   - 显性直白：所有故障注入点都是硬编码的 if/else，无循环依赖、无动态调用
//   - 仅用于测试：通过 build.zig 编译期注入（-Dfault_injection=true）
const io_uring = @import("io_uring.zig");
const mem = @import("std").mem;
const debug = @import("std").debug;

/// FaultInjector 配置 — 通过 build.zig 传入编译期常量
pub const FaultInjector = struct {
    /// 是否启用故障注入（默认 false）
    enabled: bool = false,
    /// 模拟 io_uring 初始化失败（返回错误）
    fail_io_uring_init: bool = false,
    /// 模拟 io_uring SQ 溢出（EAGAIN）
    fail_io_uring_sq_full: bool = false,
    /// 模拟磁盘写满（ENOSPC）
    fail_disk_full: bool = false,
    /// 模拟连接中断（ECONNRESET）
    fail_conn_reset: bool = false,
    /// 模拟 socket 创建失败（EMFILE/ENFILE）
    fail_socket: bool = false,
    /// 模拟 bind 失败（EADDRINUSE）
    fail_bind: bool = false,
    /// 模拟 listen 失败（EAGAIN）
    fail_listen: bool = false,
};

/// 初始化 FaultInjector（从 build options 读取）
pub fn init() FaultInjector {
    return .{
        .enabled = if (@hasDecl(@import("build_options"), "fault_injection"))
            @import("build_options").fault_injection
        else
            false,
        .fail_io_uring_init = if (@hasDecl(@import("build_options"), "fail_io_uring_init"))
            @import("build_options").fail_io_uring_init
        else
            false,
        .fail_io_uring_sq_full = if (@hasDecl(@import("build_options"), "fail_io_uring_sq_full"))
            @import("build_options").fail_io_uring_sq_full
        else
            false,
        .fail_disk_full = if (@hasDecl(@import("build_options"), "fail_disk_full"))
            @import("build_options").fail_disk_full
        else
            false,
        .fail_conn_reset = if (@hasDecl(@import("build_options"), "fail_conn_reset"))
            @import("build_options").fail_conn_reset
        else
            false,
        .fail_socket = if (@hasDecl(@import("build_options"), "fail_socket"))
            @import("build_options").fail_socket
        else
            false,
        .fail_bind = if (@hasDecl(@import("build_options"), "fail_bind"))
            @import("build_options").fail_bind
        else
            false,
        .fail_listen = if (@hasDecl(@import("build_options"), "fail_listen"))
            @import("build_options").fail_listen
        else
            false,
    };
}

/// 包装 io_uring.Ring.init，可注入初始化失败
pub fn initRing(injector: *FaultInjector) !io_uring.Ring {
    if (injector.enabled and injector.fail_io_uring_init) {
        return error.IOError;
    }
    return io_uring.Ring.init();
}

/// 包装 io_uring.Syscall.enter，可注入 SQ 溢出（EAGAIN）
pub fn submitRing(injector: *FaultInjector, ring_fd: i32, to_submit: u32, min_complete: u32) !u32 {
    if (injector.enabled and injector.fail_io_uring_sq_full) {
        return error.EAGAIN;
    }
    return io_uring.Syscall.enter(ring_fd, to_submit, min_complete, 0);
}

/// 包装 io_uring.Syscall.socket，可注入 socket 创建失败
pub fn socketFn(injector: *FaultInjector, domain: u32, type: u32, protocol: u32) !i32 {
    if (injector.enabled and injector.fail_socket) {
        return error.EMFILE;
    }
    return io_uring.Syscall.socket(domain, type, protocol);
}

/// 包装 io_uring.Syscall.bind，可注入 bind 失败
pub fn bindFn(injector: *FaultInjector, fd: i32, addr: *[]const u8, addrlen: u32) !void {
    if (injector.enabled and injector.fail_bind) {
        return error.EADDRINUSE;
    }
    // 注意：实际 bind 需要 sockaddr 结构，这里简化为只检查故障注入
    return io_uring.Syscall.bind(fd, addr, addrlen);
}

/// 包装 io_uring.Syscall.listen，可注入 listen 失败
pub fn listenFn(injector: *FaultInjector, fd: i32, backlog: u32) !void {
    if (injector.enabled and injector.fail_listen) {
        return error.EAGAIN;
    }
    return io_uring.Syscall.listen(fd, backlog);
}

/// 模拟磁盘写满（在 file_store 或 ssd_persist 中使用）
pub fn checkDiskFull(injector: *FaultInjector) void {
    if (injector.enabled and injector.fail_disk_full) {
        // 在这里可以触发错误，例如返回 ENOSPC
        // 由于这是一个 void 函数，我们只能通过全局变量或 panic 来表示错误
        // 为简单起见，我们使用断言来在测试中捕获此条件
        debug.assert(false, "Disk full fault injected");
    }
}

/// 模拟连接中断（在处理 CQE 时使用）
pub fn checkConnReset(injector: *FaultInjector) void {
    if (injector.enabled and injector.fail_conn_reset) {
        debug.assert(false, "Connection reset fault injected");
    }
}

test "FaultInjector: 默认情况下不启用故障注入" {
    const injector = FaultInjector.init();
    debug.assert(!injector.enabled);
    debug.assert(!injector.fail_io_uring_init);
    debug.assert(!injector.fail_io_uring_sq_full);
    debug.assert(!injector.fail_disk_full);
    debug.assert(!injector.fail_conn_reset);
    debug.assert(!injector.fail_socket);
    debug.assert(!injector.fail_bind);
    debug.assert(!injector.fail_listen);
}

test "FaultInjector: 启用所有故障注入开关时" {
    // 注意：此测试仅在带有适当 build options 时才有意义
    // 为了演示，我们手动设置字段
    var injector = FaultInjector{
        .enabled = true,
        .fail_io_uring_init = true,
        .fail_io_uring_sq_full = true,
        .fail_disk_full = true,
        .fail_conn_reset = true,
        .fail_socket = true,
        .fail_bind = true,
        .fail_listen = true,
    };
    debug.assert(injector.enabled);
    debug.assert(injector.fail_io_uring_init);
    debug.assert(injector.fail_io_uring_sq_full);
    debug.assert(injector.fail_disk_full);
    debug.assert(injector.fail_conn_reset);
    debug.assert(injector.fail_socket);
    debug.assert(injector.fail_bind);
    debug.assert(injector.fail_listen);
}
