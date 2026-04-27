// src/io_uring.zig
// ZigClaw V2.4 | 泥泞合成骨架 | 绝对禁止高级封装
// 修正：SQ_DEPTH/SQ_MASK 降级为 comptime_int，配合 reactor.zig 守卫

pub const SQ_DEPTH = 1024;
pub const SQ_MASK = SQ_DEPTH - 1;

// Network constants (top-level, accessible via io_uring.AF_INET etc.)
pub const AF_INET: u32 = 2;
pub const SOCK_STREAM: u32 = 1;
pub const INADDR_LOOPBACK: u32 = 0x0100007F;

pub const IOOp = enum(u8) {
    NOP = 0,           // IORING_OP_NOP
    ReadV = 1,         // IORING_OP_READV
    WriteV = 2,        // IORING_OP_WRITEV
    FSync = 3,         // IORING_OP_FSYNC
    ReadFixed = 4,     // IORING_OP_READ_FIXED
    WriteFixed = 5,    // IORING_OP_WRITE_FIXED
    PollAdd = 6,       // IORING_OP_POLL_ADD
    PollRemove = 7,    // IORING_OP_POLL_REMOVE
    Accept = 13,    // IORING_OP_ACCEPT
    Read = 22,         // IORING_OP_READ
    Write = 23,        // IORING_OP_WRITE
    Recv = 27,      // IORING_OP_RECV
    Send = 26,      // IORING_OP_SEND
};

/// ZC-7-01: 链式 SQE 常量
pub const IOSQE_IO_LINK: u32 = 4;  // ZC-7-01 修正: IOSQE_IO_LINK_BIT=2, 1<<2=4
// IOSQE bit 位图: bit0=FIXED_FILE(1), bit1=IO_DRAIN(2), bit2=IO_LINK(4), bit3=IO_HARDLINK(8)
pub const ECANCELED: i32 = 125;    // -ECANCELED = -125，链断裂时被取消的 CQE res

// === 阶段 2：内核 UAPI 1:1 内存镜像 ===

/// 严格映射 Linux 内核 struct io_uring_sqe (64 bytes)
/// 禁止添加任何 Zig 级别的抽象字段，禁止改变顺序
pub const SqEntry = extern struct {
    opcode: u8,
    flags: u8,
    ioprio: u16,
    fd: i32,
    off: u64,
    addr: u64,
    len: u32,
    __pad1: u32,
    user_data: u64,
    buf_index: u16,
    personality: u16,
    splice_fd_in: u32,
    addr3: u64,
    __pad2: u64,
};

comptime {
    if (@sizeOf(SqEntry) != 64) @compileError("ZC-FATAL: SqEntry must be exactly 64 bytes");
}

/// 严格映射 Linux 内核 struct io_uring_cqe (16 bytes)
pub const CqEntry = extern struct {
    user_data: u64,
    res: i32,
    flags: u32,
};

comptime {
    if (@sizeOf(CqEntry) != 16) @compileError("ZC-FATAL: CqEntry must be exactly 16 bytes");
}

/// 严格映射 Linux 内核 struct iovec (16 bytes)
pub const Iovec = extern struct {
    iov_base: [*]u8,
    iov_len: usize,
};

comptime {
    if (@sizeOf(Iovec) != 16) @compileError("ZC-FATAL: Iovec must be exactly 16 bytes");
}

pub const Ring = struct {
    fd: u32,
    sq_head: *u32,
    sq_tail: *u32,
    sq_ring_mask: u32,
    sq_array: [*]u32,      // SQ 索引数组：sq_array[idx] = sqe_index
    sq_entries: [*]SqEntry, // 改动：SubmissionEntry -> SqEntry
    cq_head: *u32,
    cq_tail: *u32,
    cq_ring_mask: u32,      // 新增
    cqes: [*]CqEntry,       // 改动：?*anyopaque -> [*]CqEntry
    pub fn init() SyscallError!Ring {
        var params = SetupParams{
            .sq_entries = 0, .cq_entries = 0, .flags = 0,
            .sq_thread_cpu = 0, .sq_thread_idle = 0, .features = 0, .wq_fd = 0,
            .resv = [_]u32{0} ** 3,
            .sq_off = .{ .head = 0, .tail = 0, .ring_mask = 0, .ring_entries = 0, .flags = 0, .dropped = 0, .array = 0, .resv1 = 0, .user_addr = 0 },
            .cq_off = .{ .head = 0, .tail = 0, .ring_mask = 0, .ring_entries = 0, .overflow = 0, .cqes = 0, .flags = 0, .resv1 = 0, .user_addr = 0 },
        };

        // === 阶段 1：创建 fd ===
        const fd: u32 = try Syscall.setup(1024, &params);
        errdefer Syscall.close(fd);

        // === 尺寸计算 ===
        const sq_ring_size_raw: usize = params.sq_off.array + (params.sq_entries * @sizeOf(u32));
        const cq_ring_size_raw: usize = params.cq_off.cqes + (params.cq_entries * 16);
        const sqes_size: usize = params.sq_entries * 64;
        // 内核 mmap 偏移量必须是 PAGE_SIZE 整数倍，强制向上取整
        const PAGE: usize = 4096;
        const sq_ring_size: usize = (sq_ring_size_raw + PAGE - 1) & ~(PAGE - 1);
        const cq_ring_size: usize = (cq_ring_size_raw + PAGE - 1) & ~(PAGE - 1);

        // === 阶段 2：映射 SQ ring ===
        const sq_ptr = try Syscall.map_ring(fd, 0, sq_ring_size);
        errdefer Syscall.munmap(@intFromPtr(sq_ptr), sq_ring_size);

        // === 阶段 3：映射 CQ ring ===
        // ZC-7-01 修复：CQ ring 必须用 IORING_OFF_CQ_RING = 0x8000000，不是 sq_ring_size
        // D6: CQ ring mmap offset = IORING_OFF_CQ_RING (0x8000000)，错误使用 sq_ring_size 导致
        // broken chain FSync CQE 返回 -9 而不是 -125（ECANCELED）
        const cq_ptr = try Syscall.map_ring(fd, 0x8000000, cq_ring_size);
        errdefer Syscall.munmap(@intFromPtr(cq_ptr), cq_ring_size);

        // === 阶段 4：映射 SQE 数组 ===
        // 偏移量 IORING_OFF_SQES = 0x10000000
        // 必须用 MAP_SHARED（内核共享），不能用 MAP_POPULATE（SQE 会 segfault）
        // 注意：MAP_POPULATE=0x8000，0x20000 实际是 MAP_HUGETLB（会导致大页映射失败）
        const sqes_raw = std_os.syscall6(
            .mmap,
            @as(usize, 0), // addr = NULL
            sqes_size,
            @as(usize, 0x03), // PROT_READ | PROT_WRITE
            @as(usize, 0x01), // MAP_SHARED only（SQE 禁用 MAP_POPULATE）
            @as(usize, @intCast(@as(u32, @bitCast(fd)))),
            @as(usize, 0x10000000), // IORING_OFF_SQES
        );
        if (sqes_raw == @as(usize, @bitCast(@as(isize, -1)))) { // MAP_FAILED
            return SyscallError.MmapFailed;
        }
        errdefer Syscall.munmap(sqes_raw, sqes_size);

        // === 阶段 5：构造 Ring 结构体 ===
        const sqes_aligned = @as([*]SqEntry, @ptrFromInt(sqes_raw));
        const sq_base: [*]u8 = @ptrCast(@as(?*anyopaque, sq_ptr));
        const sq_head_ptr: *u32 = @ptrCast(@alignCast(sq_base + params.sq_off.head));
        const sq_tail_ptr: *u32 = @ptrCast(@alignCast(sq_base + params.sq_off.tail));
        const sq_mask_ptr: *u32 = @ptrCast(@alignCast(sq_base + params.sq_off.ring_mask));
        const sq_mask = sq_mask_ptr.*;
        const sq_array_ptr: [*]u32 = @ptrCast(@alignCast(sq_base + params.sq_off.array));
        const cq_base: [*]u8 = @ptrCast(@as(?*anyopaque, cq_ptr));
        const cq_head_ptr: *u32 = @ptrCast(@alignCast(cq_base + params.cq_off.head));
        const cq_tail_ptr: *u32 = @ptrCast(@alignCast(cq_base + params.cq_off.tail));
        const cq_mask_ptr: *u32 = @ptrCast(@alignCast(cq_base + params.cq_off.ring_mask));
        const cq_mask = cq_mask_ptr.*;
        return .{
            .fd = fd,
            .sq_head = sq_head_ptr,
            .sq_tail = sq_tail_ptr,
            .sq_ring_mask = sq_mask,
            .sq_array = sq_array_ptr,
            .sq_entries = sqes_aligned,
            .cq_head = cq_head_ptr,
            .cq_tail = cq_tail_ptr,
            .cq_ring_mask = cq_mask,
            .cqes = @as([*]CqEntry, @ptrCast(@alignCast(cq_base + params.cq_off.cqes))),
        };
    }
};

// === 阶段 3：user_data 编码架构 ===
// IoRequest 作为 user_data 的编码载体
// 提交 SQE 时：user_data = @intFromPtr(&io_req)
// 收到 CQE 时：io_req = @as(*IoRequest, @ptrFromInt(cqe.user_data))
pub const IoRequest = struct {
    stream_id: u64,
    buf_ptr: ?*anyopaque,
};
// === ZC-1-02/04 终极修正：纯 syscall 降维层 ===
const std_os = @import("std").os.linux;

// ZC-5-01: Error union 替代 exit(1) — 生产可用性前提
pub const SyscallError = error{
    IoUringSetupFailed,
    MmapFailed,
    OpenFailed,
    SubmitFailed,
    RegisterFailed,
};
pub const SetupParams = extern struct {
    sq_entries: u32,
    cq_entries: u32,
    flags: u32,
    sq_thread_cpu: u32,
    sq_thread_idle: u32,
    features: u32,
    wq_fd: u32,
    resv: [3]u32,
    sq_off: extern struct {
        head: u32, tail: u32, ring_mask: u32, ring_entries: u32,
        flags: u32, dropped: u32, array: u32, resv1: u32, user_addr: u64,
    },
    cq_off: extern struct {
        head: u32, tail: u32, ring_mask: u32, ring_entries: u32,
        overflow: u32, cqes: u32, flags: u32, resv1: u32, user_addr: u64,
    },
};
pub const Syscall = struct {
    pub fn setup(entries: u32, params: *SetupParams) SyscallError!u32 {
        // 直接敲击 425 号门牌 (x86_64 io_uring_setup)，绕过标准库封装
        const rc = std_os.syscall3(
            .io_uring_setup,
            @as(usize, entries),
            @as(usize, @intFromPtr(params)),
            @as(usize, 0),
        );
        
        const rc_trunc: u32 = @truncate(rc);
        const fd: i32 = @bitCast(rc_trunc);
        if (fd < 0) {
            return SyscallError.IoUringSetupFailed;
        }
        return rc_trunc;
    }
    pub fn map_ring(fd: u32, offset: usize, size: usize) SyscallError!*anyopaque {
        // 强制预分配物理页，拒绝缺页中断
        // Linux x86_64 UAPI: MAP_SHARED=0x01, MAP_POPULATE=0x8000
        const flags: usize = 0x01 | 0x8000; // MAP_SHARED | MAP_POPULATE
        const prot: usize = 0x1 | 0x2; // PROT_READ | PROT_WRITE (Linux x86_64 UAPI)
        
        // 使用 syscall6 绕过 std.os.mmap，直接映射
        const ptr = std_os.syscall6(
            .mmap,
            @as(usize, 0), // addr
            @as(usize, size),
            @as(usize, prot),
            @as(usize, flags),
            @as(usize, @intCast(@as(u32, @bitCast(fd)))),
            @as(usize, offset),
        );
        if (ptr == @as(usize, @bitCast(@as(isize, -1)))) { // MAP_FAILED (Linux x86_64)
            return SyscallError.MmapFailed;
        }
        return @ptrFromInt(ptr);
    }
    pub fn enter(fd: u32, to_submit: u32, min_complete: u32, flags: u32) SyscallError!u32 {
        // ZC-3-04: min_complete > 0 时必须设置 IORING_ENTER_GETEVENTS(0x01) 标志
        const actual_flags: u32 = if (min_complete > 0) flags | 0x01 else flags;
        // ZC-7-01: 必须用 syscall6 传第6个参数(sigmask size)，
        // 否则 r9 寄存器残留值会导致链式提交行为异常
        const rc = std_os.syscall6(
            .io_uring_enter,
            @as(usize, fd),
            @as(usize, to_submit),
            @as(usize, min_complete),
            @as(usize, actual_flags),
            @as(usize, 0), // sig = NULL
            @as(usize, 0), // sz = 0 (sigmask size, unused when sig=NULL)
        );
        // 系统调用错误返回：usize 值 >= -4096
        if (rc > @as(usize, @bitCast(@as(isize, -4096)))) {
            return SyscallError.SubmitFailed;
        }
        return @intCast(rc);
    }

    pub fn close(fd: u32) void {
        _ = std_os.syscall1(.close, @as(usize, fd));
    }

    /// 内部函数：取消映射，忽略错误（清理路径无法恢复）
    /// ZC-5-02: 仅供 errdefer 清理链使用
    fn munmap(addr: usize, len: usize) void {
        _ = std_os.syscall2(.munmap, addr, len);
    }

    /// Linux UAPI 常量
    pub const AT_FDCWD: usize = 0xFFFFFFFFFFFFFF9C; // -100 sign-extended to 64-bit
    pub const O_RDONLY: u32 = 0;
    pub const O_RDWR: u32 = 2;
    pub const O_CREAT: u32 = 0x40;
    pub const O_TRUNC: u32 = 0x200;

    /// openat(dirfd, pathname, flags, mode) — 打开文件，返回 fd
    pub fn openat(dirfd: i32, path: [*:0]const u8, flags: u32, mode: u32) SyscallError!i32 {
        const rc = std_os.syscall4(
            .openat,
            @as(usize, @bitCast(@as(i64, dirfd))),
            @intFromPtr(path),
            @as(usize, flags),
            @as(usize, mode),
        );
        const result: i32 = @intCast(rc);
        if (result < 0) {
            return SyscallError.OpenFailed;
        }
        return result;
    }

    /// io_uring_register(fd, opcode, arg, nr_args)
    /// opcode 0 = IORING_REGISTER_BUFFERS（技术债：opcode 命名待修正）
    pub fn register(fd: u32, opcode: u32, arg: usize, nr_args: u32) SyscallError!void {
        const rc = std_os.syscall4(.io_uring_register, @as(usize, fd), @as(usize, opcode), arg, @as(usize, nr_args));
        // io_uring_register 成功返回 0，失败返回负 errno（作为大 usize）
        if (rc > @as(usize, @bitCast(@as(isize, -4096)))) {
            return SyscallError.RegisterFailed;
        }
    }

    /// ZC-6-01: 固定缓冲区池注册/注销
    pub const IORING_REGISTER_BUFFERS: u32 = 0;
    pub const IORING_UNREGISTER_BUFFERS: u32 = 1;

    /// 注册固定缓冲区池，成功后内核直接通过 buf_index 访问
    pub fn register_buffers(fd: u32, iovecs: [*]const Iovec, nr: u32) SyscallError!void {
        const rc = std_os.syscall4(
            .io_uring_register,
            @as(usize, fd),
            @as(usize, IORING_REGISTER_BUFFERS),
            @intFromPtr(iovecs),
            @as(usize, nr),
        );
        // io_uring_register 成功返回 0，失败返回负 errno（作为大 usize）
        if (rc > @as(usize, @bitCast(@as(isize, -4096)))) {
            return SyscallError.RegisterFailed;
        }
    }

    /// 注销固定缓冲区池，释放内核锁定
    pub fn unregister_buffers(fd: u32) SyscallError!void {
        const rc = std_os.syscall4(
            .io_uring_register,
            @as(usize, fd),
            @as(usize, IORING_UNREGISTER_BUFFERS),
            0,
            0,
        );
        // io_uring_register 成功返回 0，失败返回负 errno（作为大 usize）
        if (rc > @as(usize, @bitCast(@as(isize, -4096)))) {
            return SyscallError.RegisterFailed;
        }
    }

    /// Network constants
    pub const AF_INET: u32 = 2;
    pub const SOCK_STREAM: u32 = 1;
    pub const INADDR_LOOPBACK: u32 = 0x0100007F;

    /// htons: host -> network byte order (16-bit)
    pub fn htons(host: u16) u16 {
        return ((host & 0xFF) << 8) | ((host >> 8) & 0xFF);
    }

    /// socket(domain, type, protocol) -> fd
    pub fn socket(domain: u32, sock_type: u32, protocol: u32) SyscallError!i32 {
        const rc = std_os.syscall3(.socket, domain, sock_type, protocol);
        const result: i32 = @intCast(rc);
        if (result < 0) return SyscallError.OpenFailed;
        return result;
    }

    /// bind(fd, addr, addrlen)
    pub fn bind(fd: i32, addr: *const SockAddrIn, addrlen: u32) SyscallError!void {
        const rc = std_os.syscall3(.bind, @as(usize, @bitCast(@as(i64, fd))), @intFromPtr(addr), addrlen);
        if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return SyscallError.OpenFailed;
    }

    /// listen(fd, backlog)
    pub fn listen(fd: i32, backlog: u32) SyscallError!void {
        const rc = std_os.syscall2(.listen, @as(usize, @bitCast(@as(i64, fd))), backlog);
        if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return SyscallError.OpenFailed;
    }

    /// getsockname(fd, addr, addrlen)
    pub fn getsockname(fd: i32, addr: *SockAddrIn, addrlen: *u32) SyscallError!void {
        const rc = std_os.syscall3(.getsockname, @as(usize, @bitCast(@as(i64, fd))), @intFromPtr(addr), @intFromPtr(addrlen));
        if (rc > @as(usize, @bitCast(@as(isize, -4096)))) return SyscallError.OpenFailed;
    }

    /// connect(fd, addr, addrlen) - blocking connect (for test)
    pub fn connect(fd: i32, addr: *const SockAddrIn, addrlen: u32) SyscallError!void {
        const rc = std_os.syscall3(.connect, @as(usize, @bitCast(@as(i64, fd))), @intFromPtr(addr), addrlen);
        // ZC-9-03: 先检查是否是错误值（高位为1），避免 @intCast panic
        if (rc > 0x7FFFFFFFFFFFFFFF) {
            return SyscallError.OpenFailed;
        }
        const result: i32 = @intCast(rc);
        if (result < 0 and result != -115) return SyscallError.OpenFailed;
    }

    /// recv(fd, buf, len, flags) - blocking recv (for test verification)
    pub fn recv(fd: i32, buf: [*]u8, len: usize, flags: u32) SyscallError!i32 {
        const rc = std_os.syscall4(.recvfrom, @as(usize, @bitCast(@as(i64, fd))), @intFromPtr(buf), len, flags);
        // ZC-9-03: 先检查是否是错误值（高位为1），避免 @intCast panic
        if (rc > 0x7FFFFFFFFFFFFFFF) {
            return SyscallError.OpenFailed;
        }
        const result: i32 = @intCast(rc);
        if (result < 0) return SyscallError.OpenFailed;
        return result;
    }

    /// send(fd, buf, len, flags) — 纯 syscall 降维，不经过标准库
    pub fn send(fd: u32, buf: [*]const u8, len: usize, flags: u32) SyscallError!i32 {
        const rc = std_os.syscall4(
            .sendto,
            @as(usize, fd),
            @intFromPtr(buf),
            len,
            @as(usize, flags),
        );
        // ZC-9-03: 先检查是否是错误值（高位为1），避免 @intCast panic
        if (rc > 0x7FFFFFFFFFFFFFFF) {
            // 调试：存储错误码
            last_send_rc = rc;
            return SyscallError.OpenFailed;
        }
        const result: i32 = @intCast(rc);
        if (result < 0) {
            // 调试：存储错误码（result 是 i32 负的 errno）
            last_send_rc = @as(usize, @bitCast(@as(i64, result)));
            return SyscallError.OpenFailed;
        }
        return result;
    }
};

/// 调试用：最后一次 send 的返回值
pub var last_send_rc: usize = 0;;

/// Linux struct sockaddr_in (16 bytes, C ABI compatible)
pub const SockAddrIn = extern struct {
    family: u16 = 0,
    port: u16 = 0,
    addr: u32 = 0,
    zero: [8]u8 = .{0} ** 8,
};
