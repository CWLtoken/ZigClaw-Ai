// src/metrics.zig
// 观测层 | Layer: Observability
// 无锁原子指标收集，用于 Prometheus 格式导出

const atomic = @import("std").atomic;
const builtin = @import("std").builtin;
const fmt = @import("std").fmt;

// ============================================================================
// 缓存行对齐的原子变量包装（P2-1：伪共享消除）
// 每个原子变量独占 64 字节缓存行，防止多核/多线程下的伪共享
// ============================================================================
const CACHE_LINE = 64;

/// 缓存行对齐的原子 u64：强制独占 64 字节缓存行，消除伪共享
/// 每个原子变量单独对齐，防止多核/多线程下相邻变量共享缓存行导致性能下降
pub const AlignedAtomicU64 = struct {
    value: atomic.Value(u64) align(CACHE_LINE),
    _pad: [CACHE_LINE - @sizeOf(atomic.Value(u64))]u8 = undefined,

    pub fn init(v: u64) AlignedAtomicU64 {
        return .{ .value = atomic.Value(u64).init(v) };
    }

    pub fn load(self: *const AlignedAtomicU64, comptime order: builtin.AtomicOrder) u64 {
        return self.value.load(order);
    }

    pub fn store(self: *AlignedAtomicU64, v: u64, comptime order: builtin.AtomicOrder) void {
        self.value.store(v, order);
    }

    pub fn fetchAdd(self: *AlignedAtomicU64, v: u64, comptime order: builtin.AtomicOrder) u64 {
        return self.value.fetchAdd(v, order);
    }

    pub fn fetchSub(self: *AlignedAtomicU64, v: u64, comptime order: builtin.AtomicOrder) u64 {
        return self.value.fetchSub(v, order);
    }
};

// P-4/M-1: 编译期对齐与尺寸守卫 — 确保连续数组时每个元素独占 64B 缓存行
comptime {
    // 边界检查：确保 atomic.Value(u64) 尺寸不超过 CACHE_LINE，防止 _pad 数组下溢
    if (@sizeOf(atomic.Value(u64)) > CACHE_LINE) {
        @compileError("atomic.Value(u64) size exceeds CACHE_LINE (64), cannot safely pad");
    }
    // 结构体对齐验证
    if (@alignOf(AlignedAtomicU64) < CACHE_LINE) {
        @compileError("AlignedAtomicU64 alignment must be >= CACHE_LINE (64)");
    }
    // 结构体尺寸验证：必须是 CACHE_LINE 的整数倍
    if (@sizeOf(AlignedAtomicU64) % CACHE_LINE != 0) {
        @compileError("AlignedAtomicU64 size must be a multiple of CACHE_LINE (64)");
    }
    // 数组间距验证：确保连续数组中每个元素独占一个缓存行（终极伪共享防御）
    if (@sizeOf([2]AlignedAtomicU64) != 2 * CACHE_LINE) {
        @compileError("AlignedAtomicU64 array stride must be exactly CACHE_LINE (64) bytes");
    }
}

/// 缓存行对齐的原子 u32：强制独占 64 字节缓存行，消除伪共享
pub const AlignedAtomicU32 = struct {
    value: atomic.Value(u32) align(CACHE_LINE),
    _pad: [CACHE_LINE - @sizeOf(atomic.Value(u32))]u8 = undefined,

    pub fn init(v: u32) AlignedAtomicU32 {
        return .{ .value = atomic.Value(u32).init(v) };
    }

    pub fn load(self: *const AlignedAtomicU32, comptime order: builtin.AtomicOrder) u32 {
        return self.value.load(order);
    }

    pub fn store(self: *AlignedAtomicU32, v: u32, comptime order: builtin.AtomicOrder) void {
        self.value.store(v, order);
    }

    pub fn fetchAdd(self: *AlignedAtomicU32, v: u32, comptime order: builtin.AtomicOrder) u32 {
        return self.value.fetchAdd(v, order);
    }

    pub fn fetchSub(self: *AlignedAtomicU32, v: u32, comptime order: builtin.AtomicOrder) u32 {
        return self.value.fetchSub(v, order);
    }

    pub fn fetchOr(self: *AlignedAtomicU32, v: u32, comptime order: builtin.AtomicOrder) u32 {
        return self.value.fetchOr(v, order);
    }
};

// AlignedAtomicU32 编译期守卫
comptime {
    if (@sizeOf(atomic.Value(u32)) > CACHE_LINE) {
        @compileError("atomic.Value(u32) size exceeds CACHE_LINE (64)");
    }
    if (@alignOf(AlignedAtomicU32) < CACHE_LINE) {
        @compileError("AlignedAtomicU32 alignment must be >= CACHE_LINE (64)");
    }
    if (@sizeOf([2]AlignedAtomicU32) != 2 * CACHE_LINE) {
        @compileError("AlignedAtomicU32 array stride must be exactly CACHE_LINE (64) bytes");
    }
}
pub var http_requests_total: AlignedAtomicU64 = AlignedAtomicU64.init(0);
pub var auth_failures_total: AlignedAtomicU64 = AlignedAtomicU64.init(0);
pub var infer_total: AlignedAtomicU64 = AlignedAtomicU64.init(0);
pub var active_connections: AlignedAtomicU64 = AlignedAtomicU64.init(0);

// P49：推理延迟直方图（分桶，单位 ms）
// 分桶边界：10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, +Inf
pub const LATENCY_BUCKETS = [_]f64{ 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 };
const NUM_BUCKETS = LATENCY_BUCKETS.len + 1; // +1 for +Inf bucket

// 每个桶的计数器（静态数组，编译期零初始化）
pub var infer_latency_buckets: [NUM_BUCKETS]atomic.Value(u64) = [_]atomic.Value(u64){atomic.Value(u64).init(0)} ** NUM_BUCKETS;
const init_thresholds = [_]u64{ 100, 500, 1_000, 5_000, 10_000, 50_000, 100_000, 500_000, 1_000_000 };
var buckets_initialized = atomic.Value(bool).init(false);

// 初始化桶计数器（在程序启动时调用一次）
pub fn initLatencyBuckets() void {
    if (buckets_initialized.load(.acquire)) return;
    for (&infer_latency_buckets) |*bucket| {
        bucket.* = atomic.Value(u64).init(0);
    }
    buckets_initialized.store(true, .release);
}

// 记录推理延迟（单位 ms）
pub fn observeInferLatency(latency_ms: f64) void {
    // 确保桶已初始化
    if (!buckets_initialized.load(.acquire)) initLatencyBuckets();
    
    // 找到对应的桶
    for (LATENCY_BUCKETS, 0..) |boundary, i| {
        if (latency_ms <= boundary) {
            _ = infer_latency_buckets[i].fetchAdd(1, .monotonic);
            return;
        }
    }
    // 大于所有边界，放入 +Inf 桶
    _ = infer_latency_buckets[NUM_BUCKETS - 1].fetchAdd(1, .monotonic);
}

// P49：io_uring 操作计数（缓存行对齐）
pub var uring_accept_total: AlignedAtomicU64 = AlignedAtomicU64.init(0);
pub var uring_read_total: AlignedAtomicU64 = AlignedAtomicU64.init(0);
pub var uring_write_total: AlignedAtomicU64 = AlignedAtomicU64.init(0);

pub fn incrUringAccept() void {
    _ = uring_accept_total.fetchAdd(1, .monotonic);
}

pub fn incrUringRead() void {
    _ = uring_read_total.fetchAdd(1, .monotonic);
}

pub fn incrUringWrite() void {
    _ = uring_write_total.fetchAdd(1, .monotonic);
}

// P49：窗口槽位使用率（占位，后续从 io_uring 获取）
pub var uring_sq_ring_used: atomic.Value(u32) = atomic.Value(u32).init(0);
pub var uring_cq_ring_used: atomic.Value(u32) = atomic.Value(u32).init(0);

pub fn setSqRingUsed(n: u32) void {
    uring_sq_ring_used.store(n, .release);
}

pub fn setCqRingUsed(n: u32) void {
    uring_cq_ring_used.store(n, .release);
}

// 递增函数（调用方在入口层）
pub fn incrHttpRequests() void {
    _ = http_requests_total.fetchAdd(1, .monotonic);
}

pub fn incrAuthFailures() void {
    _ = auth_failures_total.fetchAdd(1, .monotonic);
}

pub fn incrInfer() void {
    _ = infer_total.fetchAdd(1, .monotonic);
}

pub fn incrActiveConnections() void {
    _ = active_connections.fetchAdd(1, .monotonic);
}

pub fn decrActiveConnections() void {
    _ = active_connections.fetchSub(1, .monotonic);
}

// Prometheus 格式输出（写入给定缓冲区，返回写入字节数）
/// 调用方提供缓冲区（建议 2048 字节以上）
/// 缓冲区不足时返回 MetricsError.BufferTooSmall，而非 unreachable
pub const MetricsError = error{BufferTooSmall};

pub fn formatMetrics(buf: []u8) MetricsError!usize {
    // 确保桶已初始化
    if (!buckets_initialized.load(.acquire)) initLatencyBuckets();

    const http = http_requests_total.load(.acquire);
    const auth = auth_failures_total.load(.acquire);
    const infer = infer_total.load(.acquire);
    const active = active_connections.load(.acquire);
    const accept_total = uring_accept_total.load(.acquire);
    const read_total = uring_read_total.load(.acquire);
    const write_total = uring_write_total.load(.acquire);
    const sq_used = uring_sq_ring_used.load(.acquire);
    const cq_used = uring_cq_ring_used.load(.acquire);

    // 构建延迟直方图的 bucket 行
    var bucket_lines: [1024]u8 = undefined;
    var bucket_len: usize = 0;

    // 计算累积和
    var cumulative: u64 = 0;
    for (LATENCY_BUCKETS, 0..) |boundary, i| {
        const bucket_val = infer_latency_buckets[i].load(.acquire);
        cumulative += bucket_val;
        const line = fmt.bufPrint(bucket_lines[bucket_len..],
            "zigclaw_infer_latency_ms_bucket{{le=\"{d}\"}} {d}\n",
            .{ boundary, cumulative }) catch return MetricsError.BufferTooSmall;
        bucket_len += line.len;
    }
    // +Inf 桶
    const inf_bucket = infer_latency_buckets[NUM_BUCKETS - 1].load(.acquire);
    cumulative += inf_bucket;
    const inf_line = fmt.bufPrint(bucket_lines[bucket_len..],
        "zigclaw_infer_latency_ms_bucket{{le=\"+Inf\"}} {d}\n",
        .{cumulative}) catch return MetricsError.BufferTooSmall;
    bucket_len += inf_line.len;

    const result = fmt.bufPrint(buf,
        \\# HELP zigclaw_http_requests_total Total HTTP requests
        \\# TYPE zigclaw_http_requests_total counter
        \\zigclaw_http_requests_total {d}
        \\# HELP zigclaw_auth_failures_total Authentication failures
        \\# TYPE zigclaw_auth_failures_total counter
        \\zigclaw_auth_failures_total {d}
        \\# HELP zigclaw_infer_total Total inference requests
        \\# TYPE zigclaw_infer_total counter
        \\zigclaw_infer_total {d}
        \\# HELP zigclaw_active_connections Current active connections
        \\# TYPE zigclaw_active_connections gauge
        \\zigclaw_active_connections {d}
        \\
        \\# HELP zigclaw_infer_latency_ms Inference latency in milliseconds
        \\# TYPE zigclaw_infer_latency_ms histogram
        \\{s}
        \\zigclaw_infer_latency_ms_sum 0
        \\zigclaw_infer_latency_ms_count {d}
        \\
        \\# HELP zigclaw_uring_accept_total Total accept operations
        \\# TYPE zigclaw_uring_accept_total counter
        \\zigclaw_uring_accept_total {d}
        \\# HELP zigclaw_uring_read_total Total read operations
        \\# TYPE zigclaw_uring_read_total counter
        \\zigclaw_uring_read_total {d}
        \\# HELP zigclaw_uring_write_total Total write operations
        \\# TYPE zigclaw_uring_write_total counter
        \\zigclaw_uring_write_total {d}
        \\
        \\# HELP zigclaw_uring_sq_ring_used SQ ring entries used
        \\# TYPE zigclaw_uring_sq_ring_used gauge
        \\zigclaw_uring_sq_ring_used {d}
        \\# HELP zigclaw_uring_cq_ring_used CQ ring entries used
        \\# TYPE zigclaw_uring_cq_ring_used gauge
        \\zigclaw_uring_cq_ring_used {d}
        \\
    , .{ http, auth, infer, active, bucket_lines[0..bucket_len], infer, accept_total, read_total, write_total, sq_used, cq_used }) catch return MetricsError.BufferTooSmall;

    return result.len;
}

/// 安全包装：格式化指标到缓冲区，不足时返回错误码而非 panic
pub fn formatMetricsSafe(buf: []u8) ?usize {
    return formatMetrics(buf) catch null;
}
