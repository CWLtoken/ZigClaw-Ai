// src/feedback.zig
// Feedback learning interface – v3.0 integration point
// 观测层契约 + 大模型反馈学习接口。不包含可执行代码。
//
// 使用方式：
//   const feedback = @import("feedback.zig");
//   const Learner = feedback.Learner;
//   // v3.0 实现 Learner.VTable 的具体函数
//
// 本文件固化五层指标模型和反馈学习接口，为 v3.0 大模型接入提供类型锚点。

// feedback.zig: 纯类型锚点，无 std 运行时依赖

// ============================================================================
// 层标识
// ============================================================================

pub const Layer = enum {
    entry,
    orchestrator,
    execution,
    router,
    storage,
};

// ============================================================================
// 层指标（每层上报的数据结构不同，用 union 显式区分）
// ============================================================================

pub const LayerMetrics = union(Layer) {
    entry:          EntryMetrics,
    orchestrator:   OrchMetrics,
    execution:      ExecMetrics,
    router:         RouterMetrics,
    storage:        StorageMetrics,
};

/// 全量指标快照（所有层的指标聚合，非 union，可同时持有所有层）
pub const AllMetrics = struct {
    entry:          EntryMetrics,
    orchestrator:   OrchMetrics,
    execution:      ExecMetrics,
    router:         RouterMetrics,
    storage:        StorageMetrics,
};

pub const EntryMetrics = struct {
    request_count:      u64,
    error_count:        u64,
    p50_latency_us:     u64,
    p99_latency_us:     u64,
    active_connections: u32,
};

pub const OrchMetrics = struct {
    modality_switch_count: u64,
    quantize_time_us:      u64,
    token_count:           u64,
    brain_hit_count:       [8]u64,
};

pub const ExecMetrics = struct {
    uring_submit_count:      u64,
    uring_cqe_count:         u64,
    syscall_fallback_count:  u64,
    ring_full_count:         u64,
};

pub const RouterMetrics = struct {
    route_hit:         u64,
    route_miss:        u64,
    middleware_reject: u64,
};

pub const StorageMetrics = struct {
    heat_pool_hit:          u64,
    heat_pool_miss:         u64,
    ssd_flush_count:        u64,
    vector_search_count:    u64,
    arena_bytes_allocated:  u64,
};

// ============================================================================
// 优化建议（大模型输出）
// ============================================================================

pub const Suggestion = struct {
    layer:      Layer,
    confidence: f32,  // 0.0 ~ 1.0
    action:     Action,

    pub const Action = union(enum) {
        adjust_pool_size:  struct { current: u32, recommended: u32 },
        adjust_timeout:    struct { current_ms: u32, recommended_ms: u32 },
        adjust_batch_size: struct { current: u32, recommended: u32 },
        enable_sq_poll:    struct { idle_ms: u32 },
        disable_feature:   struct { feature: []const u8, reason: []const u8 },
    };
};

// ============================================================================
// 反馈学习引擎接口
// ============================================================================

pub const Learner = struct {
    impl:   *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        observe: *const fn(impl: *anyopaque, layer: Layer, metrics: LayerMetrics) void,
        suggest: *const fn(impl: *anyopaque, layer: Layer) ?Suggestion,
        apply:   *const fn(impl: *anyopaque, suggestion: Suggestion) anyerror!void,
    };

    pub inline fn observe(self: *Learner, layer: Layer, m: LayerMetrics) void {
        self.vtable.observe(self.impl, layer, m);
    }
    pub inline fn suggest(self: *Learner, layer: Layer) ?Suggestion {
        return self.vtable.suggest(self.impl, layer);
    }
    pub inline fn apply(self: *Learner, s: Suggestion) anyerror!void {
        return self.vtable.apply(self.impl, s);
    }
};
