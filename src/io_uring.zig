// src/io_uring.zig
// ZigClaw V2.4 | 泥泞合成骨架 | 绝对禁止高级封装
// 修正：SQ_DEPTH/SQ_MASK 降级为 comptime_int，配合 reactor.zig 守卫

pub const SQ_DEPTH = 1024;
pub const SQ_MASK = SQ_DEPTH - 1;

pub const IOOp = enum(u8) {
    Read = 0,
    Write = 1,
};

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

pub const Ring = struct {
    fd: i32,
    sq_head: *u32,
    sq_tail: *u32,
    sq_ring_mask: u32,
    sq_entries: [*]SqEntry, // 改动：SubmissionEntry -> SqEntry
    cq_head: *u32,
    cq_tail: *u32,
    cq_ring_mask: u32,      // 新增
    cqes: [*]CqEntry,       // 改动：?*anyopaque -> [*]CqEntry
    pub fn init() Ring {
        var params = SetupParams{
            .sq_entries = 0, .cq_entries = 0, .flags = 0,
            .sq_thread_cpu = 0, .sq_thread_idle = 0, .features = 0, .wq_fd = 0,
            .resv = [_]u32{0} ** 3,
            .sq_off = .{ .head = 0, .tail = 0, .ring_mask = 0, .ring_entries = 0, .flags = 0, .dropped = 0, .array = 0, .resv1 = 0, .user_addr = 0 },
            .cq_off = .{ .head = 0, .tail = 0, .ring_mask = 0, .ring_entries = 0, .overflow = 0, .cqes = 0, .flags = 0, .resv1 = 0, .user_addr = 0 },
        };
        
        const fd = Syscall.setup(1024, &params);
        const sq_ring_size_raw: usize = params.sq_off.array + (params.sq_entries * @sizeOf(u32));
        const cq_ring_size_raw: usize = params.cq_off.cqes + (params.cq_entries * 16);
        const sqes_size: usize = params.sq_entries * 64;
        // 内核 mmap 偏移量必须是 PAGE_SIZE 整数倍，强制向上取整
        const PAGE: usize = 4096;
        const sq_ring_size: usize = (sq_ring_size_raw + PAGE - 1) & ~(PAGE - 1);
        const cq_ring_size: usize = (cq_ring_size_raw + PAGE - 1) & ~(PAGE - 1);
        const sq_ptr = Syscall.map_ring(fd, 0, sq_ring_size);
        const cq_ptr = Syscall.map_ring(fd, sq_ring_size, cq_ring_size);
        const sqes_ptr = Syscall.map_ring(fd, sq_ring_size + cq_ring_size, sqes_size);
        const sq_base: [*]u8 = @ptrCast(@as(?*anyopaque, sq_ptr));
        const sq_head_ptr: *u32 = @ptrCast(@alignCast(sq_base + params.sq_off.head));
        const sq_tail_ptr: *u32 = @ptrCast(@alignCast(sq_base + params.sq_off.tail));
        const sq_mask_ptr: *u32 = @ptrCast(@alignCast(sq_base + params.sq_off.ring_mask));
        const sq_mask = sq_mask_ptr.*;
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
            .sq_entries = @as([*]SqEntry, @ptrCast(@alignCast(@as(?*anyopaque, sqes_ptr)))),
            .cq_head = cq_head_ptr,
            .cq_tail = cq_tail_ptr,
            .cq_ring_mask = cq_mask,
            .cqes = @as([*]CqEntry, @ptrCast(@alignCast(cq_base + params.cq_off.cqes))),
        };
    }
};
// === ZC-1-02/04 终极修正：纯 syscall 降维层 ===
const std_os = @import("std").os.linux;
const std_process = @import("std").process;
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
    pub fn setup(entries: u32, params: *SetupParams) i32 {
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
            std_process.exit(1);
        }
        return fd;
    }
    pub fn map_ring(fd: i32, offset: usize, size: usize) ?*anyopaque {
        // 强制预分配物理页，拒绝缺页中断
        const flags: usize = 0x01 | 0x20000; // MAP_SHARED | MAP_POPULATE (Linux x86_64 UAPI)
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
            std_process.exit(1);
        }
        return @ptrFromInt(ptr);
    }
};
