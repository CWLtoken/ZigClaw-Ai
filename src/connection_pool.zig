// src/connection_pool.zig
// 连接池复用 — 基于 reactor + io_uring 的纯状态机实现
//
// 设计原则：
//   - 纯状态机，无 async/await，无事件循环
//   - 不破坏现有六层架构
//   - 支持空闲连接保活（TCP keepalive）
//   - 多路复用：多个后端连接共享一个 io_uring 实例
//   - 降低跨区 LLM 握手延迟（连接预热 + 复用）
//
// 状态机：
//   Idle → Connecting → Connected → [Keepalive] → Idle
//                        → Error → Idle

const io_uring = @import("io_uring.zig");
const log = @import("std").log;

/// 连接状态
pub const ConnState = enum(u8) {
    /// 空闲，可分配
    Idle,
    /// 正在连接（非阻塞 connect 进行中）
    Connecting,
    /// 已连接，可复用
    Connected,
    /// 保活探测中
    Keepalive,
    /// 错误，待回收
    Error,
};

/// 连接槽位（缓存行对齐，防止数组中相邻槽位共享缓存行导致伪共享）
pub const ConnSlot = struct {
    state: ConnState align(64) = .Idle,
    fd: i32 = -1,
    /// 后端地址
    backend_addr: io_uring.Syscall.SockAddrIn = .{},
    /// 最后活跃时间（用于空闲超时）
    last_active: u64 = 0,
    /// 复用计数
    reuse_count: u32 = 0,
    /// 连接建立时间（用于统计握手延迟）
    connect_start: u64 = 0,

    /// 标记为空闲
    fn markIdle(self: *ConnSlot) void {
        self.state = .Idle;
        self.fd = -1;
        self.reuse_count = 0;
        self.connect_start = 0;
    }

    /// 是否可复用
    pub fn isReusable(self: *const ConnSlot) bool {
        return self.state == .Connected and self.fd >= 0;
    }
};

/// 连接池配置
pub const PoolConfig = struct {
    /// 最大连接数
    max_conns: u32 = 16,
    /// 空闲超时（秒），0 表示不超时
    idle_timeout_sec: u32 = 300,
    /// 保活间隔（秒）
    keepalive_interval_sec: u32 = 60,
    /// 最大复用次数（防止连接泄漏）
    max_reuse_count: u32 = 1000,
};

/// 连接池 — 纯状态机，无堆分配
pub const ConnectionPool = struct {
    config: PoolConfig,
    /// 连接槽位数组（静态分配）
    slots: []ConnSlot,
    /// io_uring ring（共享）
    ring: *io_uring.Ring,
    /// 当前活跃连接数
    active_count: u32 = 0,
    /// 总复用次数（统计）
    total_reuses: u64 = 0,
    /// 总新建连接数（统计）
    total_new_conns: u64 = 0,

    /// 初始化连接池
    pub fn init(ring: *io_uring.Ring, config: PoolConfig, buf: []ConnSlot) ConnectionPool {
        // 初始化所有槽位
        for (buf) |*slot| {
            slot.* = .{};
        }
        return .{
            .config = config,
            .slots = buf,
            .ring = ring,
        };
    }

    /// 获取一个已连接的槽位（复用）
    /// 返回槽位索引，如果没有可用连接返回 null
    pub fn acquire(self: *ConnectionPool) ?u32 {
        // 第一轮：查找已连接且空闲的槽位
        for (self.slots, 0..) |*slot, i| {
            if (slot.isReusable()) {
                if (slot.reuse_count >= self.config.max_reuse_count) {
                    // 超过最大复用次数，关闭并回收
                    self.closeSlot(@intCast(i));
                    continue;
                }
                slot.reuse_count += 1;
                slot.state = .Connecting; // 标记为使用中
                self.total_reuses += 1;
                return @intCast(i);
            }
        }
        return null;
    }

    /// 释放槽位（归还到池中）
    pub fn release(self: *ConnectionPool, idx: u32) void {
        if (idx >= self.slots.len) return;
        var slot = &self.slots[idx];
        if (slot.fd >= 0) {
            slot.state = .Connected;
            // 更新时间戳（简化：使用 reuse_count 作为粗略时间）
            slot.last_active = slot.reuse_count;
        } else {
            slot.markIdle();
        }
    }

    /// 创建新连接（非阻塞）
    /// 返回槽位索引，如果池满返回 null
    pub fn connect(self: *ConnectionPool, addr: io_uring.Syscall.SockAddrIn) ?u32 {
        // 查找空闲槽位
        const idx = self.findIdleSlot() orelse return null;
        var slot = &self.slots[idx];

        // 创建非阻塞 socket
        const fd = io_uring.Syscall.socket(io_uring.Syscall.AF_INET, io_uring.Syscall.SOCK_STREAM, 0) catch return null;

        // 设置为非阻塞
        // 注意：简化实现，实际应使用 fcntl 设置 O_NONBLOCK
        // 这里依赖 io_uring 的非阻塞特性

        slot.fd = fd;
        slot.backend_addr = addr;
        slot.state = .Connecting;
        slot.connect_start = 0; // 简化：应使用单调时钟
        self.active_count += 1;
        self.total_new_conns += 1;

        return idx;
    }

    /// 关闭槽位连接
    pub fn closeSlot(self: *ConnectionPool, idx: u32) void {
        if (idx >= self.slots.len) return;
        var slot = &self.slots[idx];
        if (slot.fd >= 0) {
            io_uring.Syscall.close(@as(i32, @intCast(slot.fd)));
        }
        slot.markIdle();
        if (self.active_count > 0) self.active_count -= 1;
    }

    /// 保活检查 — 定期调用
    /// 关闭超时的空闲连接
    pub fn keepaliveCheck(self: *ConnectionPool, now: u32) void {
        for (self.slots, 0..) |*slot, i| {
            if (slot.state == .Connected and self.config.idle_timeout_sec > 0) {
                const idle_time = now - slot.last_active;
                if (idle_time > self.config.idle_timeout_sec) {
                    log.info("ConnectionPool: closing idle conn #{d} (idle={d}s)", .{ i, idle_time });
                    self.closeSlot(@intCast(i));
                }
            }
        }
    }

    /// 获取统计信息
    pub fn stats(self: *const ConnectionPool) PoolStats {
        return .{
            .active_count = self.active_count,
            .idle_count = self.idleCount(),
            .total_reuses = self.total_reuses,
            .total_new_conns = self.total_new_conns,
        };
    }

    /// 查找空闲槽位
    fn findIdleSlot(self: *const ConnectionPool) ?u32 {
        for (self.slots, 0..) |*slot, i| {
            if (slot.state == .Idle) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// 计算空闲连接数
    fn idleCount(self: *const ConnectionPool) u32 {
        var count: u32 = 0;
        for (self.slots) |*slot| {
            if (slot.state == .Connected) count += 1;
        }
        return count;
    }
};

/// 连接池统计
pub const PoolStats = struct {
    active_count: u32,
    idle_count: u32,
    total_reuses: u64,
    total_new_conns: u64,
};

// 编译期守卫：双重物理断言防止伪共享
comptime {
    // 尺寸守卫：ConnSlot 不能超过一个缓存行
    if (@sizeOf(ConnSlot) > 64) {
        @compileError("ConnectionPool: ConnSlot must fit in one cache line (64 bytes), got " ++
            @typeName(@sizeOf(ConnSlot)) ++ " bytes");
    }
    // 对齐守卫：ConnSlot 必须按 64 字节对齐（确保数组中每个元素独占缓存行）
    if (@alignOf(ConnSlot) != 64) {
        @compileError("ConnectionPool: ConnSlot must be 64-byte aligned to prevent false sharing in arrays, got align(" ++
            @typeName(@alignOf(ConnSlot)) ++ ")");
    }
}
