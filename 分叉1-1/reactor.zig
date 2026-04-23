// src/reactor.zig
// ZigClaw V2.4 Phase5 | 硬件隔离层 SPSC 原子化改造 | 打通血管新增buf_ptr孔位
const io_uring = @import("io_uring.zig");

/// 硬件IO事件: 纯透传原始元数据,Phase5新增buf_ptr血液指针孔位
pub const Event = union(enum) {
    IoComplete: struct {
        user_data: u64,
        result: u32,
        buf_ptr: ?*anyopaque, // Phase5: 血液指针孔位，打通血管
    },
    Idle,
};

/// Reactor 核心: 纯硬件盲盒,仅持有io_uring队列,严格SPSC模型原子操作
pub const Reactor = struct {
    ring: io_uring.Ring,

    pub fn init(ring: io_uring.Ring) Reactor {
        return .{ .ring = ring };
    }

    /// SPSC 模型轮询: Phase5新增buf_ptr透传
    pub fn poll(self: *Reactor) Event {
        // 原子读取生产者尾指针: .acquire屏障（严格小写）
        const sq_tail = @atomicLoad(u32, &self.ring.sq_tail, .acquire);
        // 原子读取消费者头指针: .acquire屏障（严格小写）
        const sq_head = @atomicLoad(u32, &self.ring.sq_head, .acquire);

        // 饱和减法判空,防整数回绕误判
        if (sq_tail -% sq_head == 0) return .Idle;

        // 计算当前消费槽位,幂等无副作用
        const idx = sq_head & io_uring.SQ_MASK;
        // 读取SQE: 因.acquire屏障,已确保生产者写入的内容完整可见
        const entry = &self.ring.sq_entries[idx];

        // 原子推进消费者头指针: .release屏障（严格小写）
        @atomicStore(u32, &self.ring.sq_head, sq_head + 1, .release);

        // 纯透传事件,Phase5新增buf_ptr透传（血液指针打通）
        return Event{
            .IoComplete = .{
                .user_data = entry.user_data,
                .result = entry.buf_len,
                .buf_ptr = entry.buf_ptr, // Phase5: 透传血液指针，血管打通
            },
        };
    }

    // Zig 0.16 编译期物理守卫 - Phase5更新IoComplete尺寸到24
    comptime {
        // 核心守卫: Reactor必须与Ring完全同构,无额外字段
        if (@offsetOf(Reactor, "ring") != 0) {
            @compileError("ZC-FATAL: Reactor's only field must be ring at offset 0");
        }
        if (@sizeOf(Reactor) != @sizeOf(io_uring.Ring)) {
            @compileError("ZC-FATAL: Reactor must be exactly the size of io_uring.Ring, no extra fields");
        }

        // SQ_DEPTH必须为2的幂,mask操作合法
        const dummy_ring = io_uring.Ring.init();
        _ = dummy_ring.sq_head;
        _ = dummy_ring.sq_tail;
        _ = dummy_ring.sq_entries;
        _ = io_uring.SQ_MASK;
        if ((io_uring.SQ_DEPTH & (io_uring.SQ_DEPTH - 1)) != 0) {
            @compileError("ZC-FATAL: SQ_DEPTH must be power of 2, mask operation is invalid");
        }

        // Zig 0.16 原子操作语法校验（严格小写内存序）
        var dummy_u32: u32 = 0;
        @atomicStore(u32, &dummy_u32, 1, .release);
        _ = @atomicLoad(u32, &dummy_u32, .acquire);

        // Phase5更新: IoComplete物理尺寸校验 - u64(8)+u32(4)+pad(4)+?*anyopaque(8)=24
        if (@sizeOf(Event.IoComplete) != 24) {
            @compileError("ZC-FATAL: IoComplete must be exactly 24 bytes after buf_ptr addition");
        }

        // sq_head/sq_tail类型校验: 必须为u32,原子操作合法
        if (@TypeOf(io_uring.Ring.sq_head) != u32 or @TypeOf(io_uring.Ring.sq_tail) != u32) {
            @compileError("ZC-FATAL: sq_head/sq_tail must be u32 for atomic operations");
        }
    }
};