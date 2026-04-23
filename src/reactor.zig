// src/reactor.zig
// ZigClaw V2.4 Phase5 | SPSC硬件隔离层 | buf_ptr血液指针孔位 | Zig 0.16 @typeInfo 物理守卫
const io_uring = @import("io_uring.zig");

pub const Event = union(enum) {
    IoComplete: struct {
        user_data: u64,
        result: u32,
        buf_ptr: ?*anyopaque,
    },
    Idle,
};

pub const Reactor = struct {
    ring: io_uring.Ring,

    pub fn init(ring: io_uring.Ring) Reactor {
        return .{ .ring = ring };
    }

    pub fn poll(self: *Reactor) Event {
        const sq_tail = @atomicLoad(u32, self.ring.sq_tail, .acquire);
        const sq_head = @atomicLoad(u32, self.ring.sq_head, .acquire);

        if (sq_tail -% sq_head == 0) return .Idle;

        const idx = sq_head & io_uring.SQ_MASK;
        const entry = &self.ring.sq_entries[idx];

        @atomicStore(u32, self.ring.sq_head, sq_head + 1, .release);

        return Event{
            .IoComplete = .{
                .user_data = entry.user_data,
                .result = entry.buf_len,
                .buf_ptr = entry.buf_ptr,
            },
        };
    }

    comptime {
        // ==========================================
        // 守卫 1：@typeInfo 下标硬取 IoComplete 布局 + 锚定已知值
        // 计算过程即文档，锚定值即防护
        // 纯正泥泞守卫，零 std 依赖
        // ==========================================
        const IoComplete = @typeInfo(Event).@"union".fields[0].type;
        const fields = @typeInfo(IoComplete).@"struct".fields;
        var computed: usize = 0;
        var max_align: usize = 1;

        // 【已修复】去掉 inline，comptime 块里不需要
        for (fields) |f| {
            const fa = @alignOf(f.type);
            if (fa > max_align) max_align = fa;
            const mis = computed % fa;
            if (mis != 0) computed += fa - mis;
            computed += @sizeOf(f.type);
        }
        const tail = computed % max_align;
        if (tail != 0) computed += max_align - tail;

        // 算法自洽验证（永远应为真，除非编译器bug）
        if (computed != @sizeOf(IoComplete)) {
            @compileError("ZC-FATAL: layout algorithm diverges from compiler");
        }
        // 锚定已知值（防止字段被篡改）
        if (@sizeOf(IoComplete) != 24) {
            @compileError("ZC-FATAL: IoComplete must be 24 bytes, field tampering detected");
        }

        // ==========================================
        // 守卫 2：SQ_DEPTH 必须为 comptime_int 且为 2 的幂
        // ==========================================
        if (@TypeOf(io_uring.SQ_DEPTH) != comptime_int) {
            @compileError("ZC-FATAL: SQ_DEPTH must be comptime_int");
        }
        if (io_uring.SQ_DEPTH <= 0) {
            @compileError("ZC-FATAL: SQ_DEPTH must be > 0");
        }
        if ((io_uring.SQ_DEPTH & (io_uring.SQ_DEPTH - 1)) != 0) {
            @compileError("ZC-FATAL: SQ_DEPTH must be power of 2");
        }

        // ==========================================
        // 守卫 4：原子操作语法 + 类型校验
        // ==========================================
        var dummy_u32: u32 = 0;
        @atomicStore(u32, &dummy_u32, 1, .release);
        _ = @atomicLoad(u32, &dummy_u32, .acquire);

        _ = io_uring.SQ_MASK;
    }
};