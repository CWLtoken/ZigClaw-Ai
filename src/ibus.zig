// src/ibus.zig
// 观测层 | Layer: Observability
// DRD-058: V3 IBus 内省总线 — 真实可操作的观测总线
//
// 功能：
//   1. 全局 LayerMetrics 原子变量（Mutex 保护），各层通过 record() 更新
//   2. formatBusStatus() 遍历所有原子变量，格式化为 JSON
//   3. 保留原有 emit() 日志事件功能
//
// 架构约束：
//   - 不动 reactor.zig / protocol.zig / io_uring.zig
//   - 对齐 feedback.zig 中的 LayerMetrics 联合类型
//   - 无堆：所有指标存储在 Mutex 保护的全局静态变量中
//   - 原子性：所有全局指标通过 std.Mutex 保护，消除数据竞争

const debug = @import("std").debug;
const feedback = @import("feedback.zig");
const mem = @import("std").mem;
const atomic = @import("std").atomic;



// ============================================================================
// DRD-058: LayerMetrics 原子变量（Mutex 保护）
// ============================================================================

var g_entry_metrics: feedback.EntryMetrics = .{
    .request_count = 0,
    .error_count = 0,
    .p50_latency_us = 0,
    .p99_latency_us = 0,
    .active_connections = 0,
};
var g_entry_mu: atomic.Mutex = .unlocked;

var g_orch_metrics: feedback.OrchMetrics = .{
    .modality_switch_count = 0,
    .quantize_time_us = 0,
    .token_count = 0,
    .brain_hit_count = [_]u64{0} ** 8,
};
var g_orch_mu: atomic.Mutex = .unlocked;

var g_exec_metrics: feedback.ExecMetrics = .{
    .uring_submit_count = 0,
    .uring_cqe_count = 0,
    .syscall_fallback_count = 0,
    .ring_full_count = 0,
};
var g_exec_mu: atomic.Mutex = .unlocked;

var g_router_metrics: feedback.RouterMetrics = .{
    .route_hit = 0,
    .route_miss = 0,
    .middleware_reject = 0,
};
var g_router_mu: atomic.Mutex = .unlocked;

var g_storage_metrics: feedback.StorageMetrics = .{
    .heat_pool_hit = 0,
    .heat_pool_miss = 0,
    .ssd_flush_count = 0,
    .vector_search_count = 0,
    .arena_bytes_allocated = 0,
};
var g_storage_mu: atomic.Mutex = .unlocked;

/// 初始化所有指标（在 main.zig 启动时调用）
pub fn init() void {
    while (!g_entry_mu.tryLock()) {}
    defer g_entry_mu.unlock();
    while (!g_orch_mu.tryLock()) {}
    defer g_orch_mu.unlock();
    while (!g_exec_mu.tryLock()) {}
    defer g_exec_mu.unlock();
    while (!g_router_mu.tryLock()) {}
    defer g_router_mu.unlock();
    while (!g_storage_mu.tryLock()) {}
    defer g_storage_mu.unlock();

    g_entry_metrics = .{
        .request_count = 0,
        .error_count = 0,
        .p50_latency_us = 0,
        .p99_latency_us = 0,
        .active_connections = 0,
    };
    g_orch_metrics = .{
        .modality_switch_count = 0,
        .quantize_time_us = 0,
        .token_count = 0,
        .brain_hit_count = [_]u64{0} ** 8,
    };
    g_exec_metrics = .{
        .uring_submit_count = 0,
        .uring_cqe_count = 0,
        .syscall_fallback_count = 0,
        .ring_full_count = 0,
    };
    g_router_metrics = .{
        .route_hit = 0,
        .route_miss = 0,
        .middleware_reject = 0,
    };
    g_storage_metrics = .{
        .heat_pool_hit = 0,
        .heat_pool_miss = 0,
        .ssd_flush_count = 0,
        .vector_search_count = 0,
        .arena_bytes_allocated = 0,
    };
}

// ============================================================================
// DRD-058: record() — 各层调用更新指标（Mutex 保护，消除数据竞争）
// ============================================================================
pub fn record(layer: feedback.Layer, metrics: feedback.LayerMetrics) void {
    switch (layer) {
        .entry => {
            while (!g_entry_mu.tryLock()) {}
            defer g_entry_mu.unlock();
            g_entry_metrics = metrics.entry;
        },
        .orchestrator => {
            while (!g_orch_mu.tryLock()) {}
            defer g_orch_mu.unlock();
            g_orch_metrics = metrics.orchestrator;
        },
        .execution => {
            while (!g_exec_mu.tryLock()) {}
            defer g_exec_mu.unlock();
            g_exec_metrics = metrics.execution;
        },
        .router => {
            while (!g_router_mu.tryLock()) {}
            defer g_router_mu.unlock();
            g_router_metrics = metrics.router;
        },
        .storage => {
            while (!g_storage_mu.tryLock()) {}
            defer g_storage_mu.unlock();
            g_storage_metrics = metrics.storage;
        },
    }
}

/// 读取所有层指标为统一的全量快照（供上层查询）
pub fn readMetrics() feedback.AllMetrics {
    while (!g_entry_mu.tryLock()) {}
    defer g_entry_mu.unlock();
    while (!g_orch_mu.tryLock()) {}
    defer g_orch_mu.unlock();
    while (!g_exec_mu.tryLock()) {}
    defer g_exec_mu.unlock();
    while (!g_router_mu.tryLock()) {}
    defer g_router_mu.unlock();
    while (!g_storage_mu.tryLock()) {}
    defer g_storage_mu.unlock();
    return .{
        .entry = g_entry_metrics,
        .orchestrator = g_orch_metrics,
        .execution = g_exec_metrics,
        .router = g_router_metrics,
        .storage = g_storage_metrics,
    };
}

// ============================================================================
// DRD-058: formatBusStatus() — 格式化为 JSON
// 返回写入 buf 的字节数
// ============================================================================

pub fn formatBusStatus(buf: []u8) usize {
    // 加锁读取所有指标快照
    while (!g_entry_mu.tryLock()) {}
    const entry = g_entry_metrics;
    g_entry_mu.unlock();
    while (!g_orch_mu.tryLock()) {}
    const orch = g_orch_metrics;
    g_orch_mu.unlock();
    while (!g_exec_mu.tryLock()) {}
    const exec = g_exec_metrics;
    g_exec_mu.unlock();
    while (!g_router_mu.tryLock()) {}
    const router = g_router_metrics;
    g_router_mu.unlock();
    while (!g_storage_mu.tryLock()) {}
    const storage = g_storage_metrics;
    g_storage_mu.unlock();

    const w = buf;

    // 使用简单的 JSON 拼接（无堆分配）
    var pos: usize = 0;

    // 辅助：追加字符串
    const append = struct {
        fn f(b: []u8, p: *usize, s: []const u8) void {
            const n = @min(s.len, b.len - p.*);
            @memcpy(b[p.* .. p.* + n], s);
            p.* += n;
        }
    }.f;

    append(w, &pos, "{\n");

    // entry 层
    append(w, &pos, "  \"entry\": {\n");
    append(w, &pos, "    \"request_count\": ");
    pos += printU64(w[pos..], entry.request_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"error_count\": ");
    pos += printU64(w[pos..], entry.error_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"p50_latency_us\": ");
    pos += printU64(w[pos..], entry.p50_latency_us);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"p99_latency_us\": ");
    pos += printU64(w[pos..], entry.p99_latency_us);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"active_connections\": ");
    pos += printU32(w[pos..], entry.active_connections);
    append(w, &pos, "\n  },\n");

    // orchestrator 层
    append(w, &pos, "  \"orchestrator\": {\n");
    append(w, &pos, "    \"modality_switch_count\": ");
    pos += printU64(w[pos..], orch.modality_switch_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"quantize_time_us\": ");
    pos += printU64(w[pos..], orch.quantize_time_us);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"token_count\": ");
    pos += printU64(w[pos..], orch.token_count);
    append(w, &pos, "\n  },\n");

    // execution 层
    append(w, &pos, "  \"execution\": {\n");
    append(w, &pos, "    \"uring_submit_count\": ");
    pos += printU64(w[pos..], exec.uring_submit_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"uring_cqe_count\": ");
    pos += printU64(w[pos..], exec.uring_cqe_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"syscall_fallback_count\": ");
    pos += printU64(w[pos..], exec.syscall_fallback_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"ring_full_count\": ");
    pos += printU64(w[pos..], exec.ring_full_count);
    append(w, &pos, "\n  },\n");

    // router 层
    append(w, &pos, "  \"router\": {\n");
    append(w, &pos, "    \"route_hit\": ");
    pos += printU64(w[pos..], router.route_hit);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"route_miss\": ");
    pos += printU64(w[pos..], router.route_miss);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"middleware_reject\": ");
    pos += printU64(w[pos..], router.middleware_reject);
    append(w, &pos, "\n  },\n");

    // storage 层
    append(w, &pos, "  \"storage\": {\n");
    append(w, &pos, "    \"heat_pool_hit\": ");
    pos += printU64(w[pos..], storage.heat_pool_hit);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"heat_pool_miss\": ");
    pos += printU64(w[pos..], storage.heat_pool_miss);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"ssd_flush_count\": ");
    pos += printU64(w[pos..], storage.ssd_flush_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"vector_search_count\": ");
    pos += printU64(w[pos..], storage.vector_search_count);
    append(w, &pos, ",\n");
    append(w, &pos, "    \"arena_bytes_allocated\": ");
    pos += printU64(w[pos..], storage.arena_bytes_allocated);
    append(w, &pos, "\n  }\n");

    append(w, &pos, "}\n");

    return pos;
}

// ============================================================================
// F2: 二进制指标协议
// 格式: [4字节帧长度][1字节字段ID][N字节值]
// 帧长度 = 1(字段ID) + N(值)，即不含自身4字节
// sidecar 读取此二进制流后可转 Prometheus/OTLP
// ============================================================================

/// 字段 ID 枚举 — 每个指标一个唯一 ID
pub const FieldId = enum(u8) {
    entry_request_count      = 1,
    entry_error_count        = 2,
    entry_p50_latency_us     = 3,
    entry_p99_latency_us    = 4,
    entry_active_connections = 5,
    orch_modality_switch    = 6,
    orch_quantize_time_us   = 7,
    orch_token_count        = 8,
    exec_uring_submit       = 9,
    exec_uring_cqe          = 10,
    exec_syscall_fallback   = 11,
    exec_ring_full          = 12,
    router_hit              = 13,
    router_miss             = 14,
    router_middleware_reject = 15,
    storage_heat_hit        = 16,
    storage_heat_miss       = 17,
    storage_ssd_flush       = 18,
    storage_vector_search   = 19,
    storage_arena_bytes     = 20,
};

/// 将 u64 值写入小端字节序（无堆分配）
fn writeU64LE(buf: []u8, val: u64) void {
    buf[0] = @intCast(val & 0xFF);
    buf[1] = @intCast((val >> 8) & 0xFF);
    buf[2] = @intCast((val >> 16) & 0xFF);
    buf[3] = @intCast((val >> 24) & 0xFF);
    buf[4] = @intCast((val >> 32) & 0xFF);
    buf[5] = @intCast((val >> 40) & 0xFF);
    buf[6] = @intCast((val >> 48) & 0xFF);
    buf[7] = @intCast((val >> 56) & 0xFF);
}

/// 将 u32 值写入小端字节序（无堆分配）
fn writeU32LE(buf: []u8, val: u32) void {
    buf[0] = @intCast(val & 0xFF);
    buf[1] = @intCast((val >> 8) & 0xFF);
    buf[2] = @intCast((val >> 16) & 0xFF);
    buf[3] = @intCast((val >> 24) & 0xFF);
}

/// 写入单帧: [4字节长度][1字节字段ID][8字节u64值]
/// 返回写入的字节数（= 4 + 1 + 8 = 13）
fn writeU64Frame(buf: []u8, field_id: FieldId, val: u64) usize {
    if (buf.len < 13) return 0;
    // 帧长度 = 1 + 8 = 9（不含自身4字节）
    writeU32LE(buf[0..4], 9);
    buf[4] = @intFromEnum(field_id);
    writeU64LE(buf[5..13], val);
    return 13;
}

/// 写入单帧（u32 值）: [4字节长度][1字节字段ID][4字节u32值]
/// 返回写入的字节数（= 4 + 1 + 4 = 9）
fn writeU32Frame(buf: []u8, field_id: FieldId, val: u32) usize {
    if (buf.len < 9) return 0;
    // 帧长度 = 1 + 4 = 5
    writeU32LE(buf[0..4], 5);
    buf[4] = @intFromEnum(field_id);
    writeU32LE(buf[5..9], val);
    return 9;
}

/// 序列化所有指标为二进制帧流
/// 格式: 连续的多帧，每帧 [4字节长度][1字节字段ID][N字节值]
/// 返回写入的总字节数
pub fn formatBinaryMetrics(buf: []u8) usize {
    // 加锁读取所有指标快照
    while (!g_entry_mu.tryLock()) {}
    const entry = g_entry_metrics;
    g_entry_mu.unlock();
    while (!g_orch_mu.tryLock()) {}
    const orch = g_orch_metrics;
    g_orch_mu.unlock();
    while (!g_exec_mu.tryLock()) {}
    const exec = g_exec_metrics;
    g_exec_mu.unlock();
    while (!g_router_mu.tryLock()) {}
    const router = g_router_metrics;
    g_router_mu.unlock();
    while (!g_storage_mu.tryLock()) {}
    const storage = g_storage_metrics;
    g_storage_mu.unlock();

    var pos: usize = 0;

    // entry 层
    pos += writeU64Frame(buf[pos..], .entry_request_count, entry.request_count);
    pos += writeU64Frame(buf[pos..], .entry_error_count, entry.error_count);
    pos += writeU64Frame(buf[pos..], .entry_p50_latency_us, entry.p50_latency_us);
    pos += writeU64Frame(buf[pos..], .entry_p99_latency_us, entry.p99_latency_us);
    pos += writeU32Frame(buf[pos..], .entry_active_connections, entry.active_connections);

    // orchestrator 层
    pos += writeU64Frame(buf[pos..], .orch_modality_switch, orch.modality_switch_count);
    pos += writeU64Frame(buf[pos..], .orch_quantize_time_us, orch.quantize_time_us);
    pos += writeU64Frame(buf[pos..], .orch_token_count, orch.token_count);

    // execution 层
    pos += writeU64Frame(buf[pos..], .exec_uring_submit, exec.uring_submit_count);
    pos += writeU64Frame(buf[pos..], .exec_uring_cqe, exec.uring_cqe_count);
    pos += writeU64Frame(buf[pos..], .exec_syscall_fallback, exec.syscall_fallback_count);
    pos += writeU64Frame(buf[pos..], .exec_ring_full, exec.ring_full_count);

    // router 层
    pos += writeU64Frame(buf[pos..], .router_hit, router.route_hit);
    pos += writeU64Frame(buf[pos..], .router_miss, router.route_miss);
    pos += writeU64Frame(buf[pos..], .router_middleware_reject, router.middleware_reject);

    // storage 层
    pos += writeU64Frame(buf[pos..], .storage_heat_hit, storage.heat_pool_hit);
    pos += writeU64Frame(buf[pos..], .storage_heat_miss, storage.heat_pool_miss);
    pos += writeU64Frame(buf[pos..], .storage_ssd_flush, storage.ssd_flush_count);
    pos += writeU64Frame(buf[pos..], .storage_vector_search, storage.vector_search_count);
    pos += writeU64Frame(buf[pos..], .storage_arena_bytes, storage.arena_bytes_allocated);

    return pos;
}

// ============================================================================
// 数字格式化辅助（无堆分配）
// ============================================================================

fn printU64(buf: []u8, val: u64) usize {
    if (val == 0) {
        if (buf.len > 0) {
            buf[0] = '0';
            return 1;
        }
        return 0;
    }
    var tmp: [32]u8 = undefined;
    var v = val;
    var i: usize = 0;
    while (v > 0 and i < tmp.len) {
        tmp[i] = @intCast('0' + @as(u8, @intCast(v % 10)));
        v /= 10;
        i += 1;
    }
    // 反转
    var j: usize = 0;
    while (j < i and j < buf.len) {
        buf[j] = tmp[i - 1 - j];
        j += 1;
    }
    return j;
}

fn printU32(buf: []u8, val: u32) usize {
    return printU64(buf, @as(u64, val));
}

// ============================================================================
// 保留原有功能：emit() 日志事件
// ============================================================================

pub fn emit(event_name: []const u8) void {
    debug.print("[IBus] event: {s}\n", .{event_name});
}

// ============================================================================
// 单元测试（P46）— 保留 record()/readMetrics() 测试
// ============================================================================

const std_debug = @import("std").debug;

test "P46: record 和 readMetrics" {
    // 使用新的 LayerMetrics API（union 初始化只指定一个 tag）
    const entry_metrics = feedback.LayerMetrics{
        .entry = .{ .request_count = 10, .error_count = 0, .p50_latency_us = 100, .p99_latency_us = 200, .active_connections = 5 },
    };
    const orch_metrics = feedback.LayerMetrics{
        .orchestrator = .{ .modality_switch_count = 3, .quantize_time_us = 500, .token_count = 1000, .brain_hit_count = [_]u64{0} ** 8 },
    };
    const exec_metrics = feedback.LayerMetrics{
        .execution = .{ .uring_submit_count = 10, .uring_cqe_count = 10, .syscall_fallback_count = 0, .ring_full_count = 0 },
    };
    const router_metrics = feedback.LayerMetrics{
        .router = .{ .route_hit = 5, .route_miss = 0, .middleware_reject = 0 },
    };
    const storage_metrics = feedback.LayerMetrics{
        .storage = .{ .heat_pool_hit = 3, .heat_pool_miss = 0, .ssd_flush_count = 2, .vector_search_count = 5, .arena_bytes_allocated = 1024 },
    };

    record(.entry, entry_metrics);
    record(.orchestrator, orch_metrics);
    record(.execution, exec_metrics);
    record(.router, router_metrics);
    record(.storage, storage_metrics);

    const result = readMetrics();

    std_debug.assert(result.entry.request_count == 10);
    std_debug.assert(result.orchestrator.token_count == 1000);
    std_debug.assert(result.execution.uring_submit_count == 10);
    std_debug.assert(result.router.route_hit == 5);
    std_debug.assert(result.storage.heat_pool_hit == 3);
    std_debug.print("P46: IBus 观测模块测试通过\n", .{});
}
