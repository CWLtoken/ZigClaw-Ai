// src/net.zig
// ZigClaw V2.5 | 网络 syscall 封装 | 零依赖，纯 linux syscall
//
// 设计原则（显性直白）：
//   - 直接封装 linux 网络 syscall，无中间抽象层
//   - 所有错误处理显式 if-else，禁止 try/catch/orelse
//   - 零堆分配，仅使用栈上和静态内存
//   - 与 io_uring.zig 解耦：网络操作可独立测试

const linux = @import("std").os.linux;
const mem = @import("std").mem;
const testing = @import("std").testing;

/// 网络错误类型
pub const NetError = error{
    SocketFailed,
    BindFailed,
    ListenFailed,
    ConnectFailed,
    AcceptFailed,
    RecvFailed,
    SendFailed,
    GetSockNameFailed,
};

/// 网络常量
pub const AF_INET: u32 = 2;
pub const SOCK_STREAM: u32 = 1;
pub const INADDR_LOOPBACK: u32 = 0x0100007F;

/// htons - 主机字节序转网络字节序
pub fn htons(host: u16) u16 {
    return mem.bigToNative(u16, host);
}

/// socket(domain, type, protocol) -> fd
pub fn socket(domain: u32, sock_type: u32, protocol: u32) NetError!i32 {
    const rc = linux.syscall3(.socket, domain, sock_type, protocol);
    if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return NetError.SocketFailed;
    return @intCast(@as(i32, @bitCast(@as(u32, @truncate(rc)))));
}

/// bind(fd, addr, addrlen)
pub fn bind(fd: i32, addr: *const SockAddrIn, addrlen: u32) NetError!void {
    const rc = linux.syscall3(.bind, @as(usize, @bitCast(@as(i64, fd))), @intFromPtr(addr), addrlen);
    if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return NetError.BindFailed;
}

/// listen(fd, backlog)
pub fn listen(fd: i32, backlog: u32) NetError!void {
    const rc = linux.syscall2(.listen, @as(usize, @bitCast(@as(i64, fd))), backlog);
    if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return NetError.ListenFailed;
}

/// getsockname(fd, addr, addrlen)
pub fn getsockname(fd: i32, addr: *SockAddrIn, addrlen: *u32) NetError!void {
    const rc = linux.syscall3(.getsockname, @as(usize, @bitCast(@as(i64, fd))), @intFromPtr(addr), @intFromPtr(addrlen));
    if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return NetError.GetSockNameFailed;
}

/// connect(fd, addr, addrlen) - blocking connect (for test)
pub fn connect(fd: u32, addr: *const SockAddrIn, addrlen: u32) NetError!void {
    const rc = linux.syscall3(.connect, @as(usize, fd), @intFromPtr(addr), addrlen);
    if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return NetError.ConnectFailed;
}

/// recv(fd, buf, len, flags) - blocking recv (for test verification)
pub fn recv(fd: u32, buf: [*]u8, len: usize, flags: u32) NetError!i32 {
    const rc = linux.syscall4(.recvfrom, @as(usize, fd), @intFromPtr(buf), len, @as(usize, flags));
    if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return NetError.RecvFailed;
    return @intCast(@as(i32, @bitCast(@as(u32, @truncate(rc)))));
}

/// send(fd, buf, len, flags) — 纯 syscall 降维，不经过标准库
pub fn send(fd: u32, buf: [*]const u8, len: usize, flags: u32) NetError!i32 {
    const rc = linux.syscall6(
        .sendto,
        @as(usize, fd),
        @intFromPtr(buf),
        len,
        @as(usize, flags),
        @as(usize, 0), // dest_addr = NULL
        @as(usize, 0), // addrlen = 0
    );
    if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return NetError.SendFailed;
    return @intCast(@as(i32, @bitCast(@as(u32, @truncate(rc)))));
}

/// close(fd) - 关闭文件描述符
pub fn close(fd: i32) void {
    _ = linux.syscall1(.close, @as(usize, @bitCast(@as(i64, fd))));
}

/// accept(fd, addr, addrlen) - 接受连接，返回新连接的 fd
pub fn accept(fd: i32, addr: ?*SockAddrIn, addrlen: ?*u32) NetError!i32 {
    const rc = linux.syscall3(
        .accept,
        @as(usize, @bitCast(@as(i64, fd))),
        if (addr) |a| @intFromPtr(a) else 0,
        if (addrlen) |al| @intFromPtr(al) else 0,
    );
    if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return NetError.AcceptFailed;
    return @intCast(@as(i32, @bitCast(@as(u32, @truncate(rc)))));
}

/// Linux struct sockaddr_in (16 bytes, C ABI compatible)
pub const SockAddrIn = extern struct {
    family: u16 = 0,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = .{0} ** 8,
};

// ============================================================
// 测试
// ============================================================
test "SockAddrIn size" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(SockAddrIn));
}
