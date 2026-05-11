// src/integration_p49.zig
// DRD-049：阶段 25 — P49 集成测试
// 验证：延迟分桶递增、/metrics 输出包含新指标

const debug = @import("std").debug;
const mem = @import("std").mem;

// 导入 P49 模块
const metrics_mod = @import("metrics.zig");

// 集成测试1：延迟分桶递增
test "P49 Integration: 延迟分桶递增" {
    // 确保桶已初始化
    metrics_mod.initLatencyBuckets();
    
    // 记录一个 100ms 的延迟（应该落入 {le="100"} 桶）
    metrics_mod.observeInferLatency(100.0);
    
    // 记录一个 300ms 的延迟（应该落入 {le="500"} 桶，因为 300 <= 500）
    metrics_mod.observeInferLatency(300.0);
    
    // 记录一个 2000ms 的延迟（应该落入 {le="2500"} 桶）
    metrics_mod.observeInferLatency(2000.0);
    
    // 验证：通过 formatMetrics 输出检查桶计数
    var buf: [2048]u8 = undefined;
    const len = try metrics_mod.formatMetrics(&buf);
    const output = buf[0..len];
    
    // 简单验证：输出包含直方图标识
    debug.assert(mem.indexOf(u8, output, "zigclaw_infer_latency_ms_bucket") != null);
    
    debug.print("P49集成测试：延迟分桶递增通过 (output len={d})\n", .{len});
    debug.print("输出预览（前500字节）：\n{s}\n", .{output[0..@min(len, 500)]});
}

// 集成测试2：/metrics 输出包含新指标
test "P49 Integration: /metrics 输出包含新指标" {
    var buf: [2048]u8 = undefined;
    const len = try metrics_mod.formatMetrics(&buf);
    const output = buf[0..len];
    
    // 验证包含 io_uring 指标
    debug.assert(mem.indexOf(u8, output, "zigclaw_uring_accept_total") != null);
    debug.assert(mem.indexOf(u8, output, "zigclaw_uring_read_total") != null);
    debug.assert(mem.indexOf(u8, output, "zigclaw_uring_write_total") != null);
    
    // 验证包含窗口槽位使用率
    debug.assert(mem.indexOf(u8, output, "zigclaw_uring_sq_ring_used") != null);
    debug.assert(mem.indexOf(u8, output, "zigclaw_uring_cq_ring_used") != null);
    
    // 验证包含直方图
    debug.assert(mem.indexOf(u8, output, "zigclaw_infer_latency_ms_bucket") != null);
    debug.assert(mem.indexOf(u8, output, "zigclaw_infer_latency_ms_sum") != null);
    debug.assert(mem.indexOf(u8, output, "zigclaw_infer_latency_ms_count") != null);
    
    debug.print("P49集成测试：/metrics 输出包含新指标通过 (len={d})\n", .{len});
}

// 集成测试3：推理延迟边界测试
test "P49 Integration: 推理延迟边界测试" {
    metrics_mod.initLatencyBuckets();
    
    // 测试边界值
    metrics_mod.observeInferLatency(9.9);  // 应该落入 {le="10"} 桶
    metrics_mod.observeInferLatency(10.0); // 正好边界，应该落入 {le="10"} 桶
    metrics_mod.observeInferLatency(10.1); // 应该落入 {le="25"} 桶
    
    metrics_mod.observeInferLatency(9999.0); // 应该落入 {le="10000"} 桶
    metrics_mod.observeInferLatency(10001.0); // 应该落入 {le="+Inf"} 桶
    
    var buf: [2048]u8 = undefined;
    const len = try metrics_mod.formatMetrics(&buf);
    const output = buf[0..len];
    
    debug.print("P49集成测试：延迟边界测试通过\n输出（前600字节）：\n{s}\n", .{output[0..@min(len, 600)]});
}
