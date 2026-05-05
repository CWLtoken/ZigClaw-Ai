// src/ibus.zig
// 观测层 | Layer: Observability
const std = @import("std");

pub const ModelFeedback = struct {
    ssd_heat_version_flip_rate: f32,
    arena_pressure: f32,
    single_codebook_drift: f32,
    latency_attention_events: LatencyAttentionEvents,
    current_flush_interval_sec: u16,
};

pub const LatencyAttentionEvents = struct {
    count: u16,
    last_latency_ms: u16,
    context_hash: u32,
};

// 全局静态反馈缓冲区（模拟 mmap）
var feedback: ModelFeedback = ModelFeedback{
    .ssd_heat_version_flip_rate = 0,
    .arena_pressure = 0,
    .single_codebook_drift = 0,
    .latency_attention_events = .{ .count = 0, .last_latency_ms = 0, .context_hash = 0 },
    .current_flush_interval_sec = 0,
};

pub fn write_metrics(new_fb: ModelFeedback) void {
    feedback = new_fb; // 原子性由调用者保证
}

pub fn read_metrics() *const ModelFeedback {
    return &feedback;
}

// 单元测试（P46）
const std_debug = @import("std").debug;

test "P46: ModelFeedback 初始化" {
    const fb = read_metrics();
    std_debug.assert(fb.ssd_heat_version_flip_rate == 0);
    std_debug.assert(fb.arena_pressure == 0);
}

test "P46: write_metrics 和 read_metrics" {
    const new_fb: ModelFeedback = .{
        .ssd_heat_version_flip_rate = 0.5,
        .arena_pressure = 0.3,
        .single_codebook_drift = 0.1,
        .latency_attention_events = .{ .count = 10, .last_latency_ms = 50, .context_hash = 12345 },
        .current_flush_interval_sec = 30,
    };
    write_metrics(new_fb);
    
    const fb = read_metrics();
    std_debug.assert(fb.ssd_heat_version_flip_rate == 0.5);
    std_debug.assert(fb.latency_attention_events.count == 10);
    std_debug.print("P46: IBus 观测模块测试通过\n", .{});
}
