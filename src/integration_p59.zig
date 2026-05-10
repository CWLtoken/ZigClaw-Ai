// src/integration_p59.zig
// F2: 二进制指标协议集成测试
// 验证 formatBinaryMetrics() 输出的二进制帧格式正确性

const mem = @import("std").mem;
const testing = @import("std").testing;
const ibus = @import("ibus.zig");
const feedback = @import("feedback.zig");

/// 从二进制帧中读取 u32 小端
fn readU32LE(buf: []const u8) u32 {
    return @as(u32, buf[0]) |
           (@as(u32, buf[1]) << 8) |
           (@as(u32, buf[2]) << 16) |
           (@as(u32, buf[3]) << 24);
}

/// 从二进制帧中读取 u64 小端
fn readU64LE(buf: []const u8) u64 {
    return @as(u64, buf[0]) |
           (@as(u64, buf[1]) << 8) |
           (@as(u64, buf[2]) << 16) |
           (@as(u64, buf[3]) << 24) |
           (@as(u64, buf[4]) << 32) |
           (@as(u64, buf[5]) << 40) |
           (@as(u64, buf[6]) << 48) |
           (@as(u64, buf[7]) << 56);
}

/// 验证单帧: 返回帧总长度（含4字节长度头），并检查字段ID和值
fn verifyFrame(buf: []const u8, expected_field_id: u8, expected_val: u64) !usize {
    const frame_len = readU32LE(buf[0..4]);
    try testing.expectEqual(@as(u32, @intCast(1 + 8)), frame_len); // 1 byte id + 8 bytes u64
    try testing.expectEqual(@as(u8, expected_field_id), buf[4]);
    const val = readU64LE(buf[5..13]);
    try testing.expectEqual(expected_val, val);
    return 13; // 4 + 1 + 8
}

/// 验证 u32 帧
fn verifyU32Frame(buf: []const u8, expected_field_id: u8, expected_val: u32) !usize {
    const frame_len = readU32LE(buf[0..4]);
    try testing.expectEqual(@as(u32, @intCast(1 + 4)), frame_len); // 1 byte id + 4 bytes u32
    try testing.expectEqual(@as(u8, expected_field_id), buf[4]);
    const val = readU32LE(buf[5..9]);
    try testing.expectEqual(expected_val, val);
    return 9; // 4 + 1 + 4
}

test "P59-1: formatBinaryMetrics 输出非空且长度合理" {
    // 先设置一些指标值
    ibus.init();
    const m = feedback.LayerMetrics{
        .entry = .{ .request_count = 42, .error_count = 3, .p50_latency_us = 150, .p99_latency_us = 500, .active_connections = 7 },
    };
    ibus.record(.entry, m);

    var buf: [2048]u8 = undefined;
    const len = ibus.formatBinaryMetrics(&buf);

    // 20 个指标: 16 个 u64 帧(13字节) + 1 个 u32 帧(9字节) + 3 个 orch u64 帧(13字节)
    // = 19 * 13 + 1 * 9 = 247 + 9 = 256 (实际: 5 entry + 3 orch + 4 exec + 3 router + 5 storage = 20)
    // entry: 4*u64 + 1*u32 = 4*13 + 9 = 61
    // orch: 3*u64 = 39
    // exec: 4*u64 = 52
    // router: 3*u64 = 39
    // storage: 5*u64 = 65
    // total = 61 + 39 + 52 + 39 + 65 = 256
    try testing.expectEqual(@as(usize, 256), len);
}

test "P59-2: 二进制帧字段ID顺序正确" {
    ibus.init();
    // 设置特定值以便验证
    const m = feedback.LayerMetrics{
        .entry = .{ .request_count = 100, .error_count = 0, .p50_latency_us = 0, .p99_latency_us = 0, .active_connections = 0 },
    };
    ibus.record(.entry, m);

    var buf: [2048]u8 = undefined;
    const len = ibus.formatBinaryMetrics(&buf);
    try testing.expect(len > 0);

    // 验证第一帧: entry_request_count = 1, val = 100
    var offset: usize = 0;
    offset += try verifyFrame(buf[offset..], 1, 100); // entry_request_count

    // 第二帧: entry_error_count = 2, val = 0
    offset += try verifyFrame(buf[offset..], 2, 0);

    // 第三帧: entry_p50_latency_us = 3
    offset += try verifyFrame(buf[offset..], 3, 0);

    // 第四帧: entry_p99_latency_us = 4
    offset += try verifyFrame(buf[offset..], 4, 0);

    // 第五帧: entry_active_connections = 5 (u32 frame)
    offset += try verifyU32Frame(buf[offset..], 5, 0);
}

test "P59-3: 二进制帧包含所有层指标" {
    ibus.init();
    // 设置所有层指标
    ibus.record(.entry, .{ .entry = .{ .request_count = 1, .error_count = 2, .p50_latency_us = 3, .p99_latency_us = 4, .active_connections = 5 } });
    ibus.record(.orchestrator, .{ .orchestrator = .{ .modality_switch_count = 10, .quantize_time_us = 20, .token_count = 30, .brain_hit_count = [_]u64{0} ** 8 } });
    ibus.record(.execution, .{ .execution = .{ .uring_submit_count = 100, .uring_cqe_count = 100, .syscall_fallback_count = 0, .ring_full_count = 0 } });
    ibus.record(.router, .{ .router = .{ .route_hit = 50, .route_miss = 1, .middleware_reject = 0 } });
    ibus.record(.storage, .{ .storage = .{ .heat_pool_hit = 25, .heat_pool_miss = 3, .ssd_flush_count = 1, .vector_search_count = 10, .arena_bytes_allocated = 4096 } });

    var buf: [2048]u8 = undefined;
    const len = ibus.formatBinaryMetrics(&buf);
    try testing.expectEqual(@as(usize, 256), len);

    // 验证关键帧的值
    var offset: usize = 0;

    // entry 层 (5 帧)
    offset += try verifyFrame(buf[offset..], 1, 1);   // request_count
    offset += try verifyFrame(buf[offset..], 2, 2);    // error_count
    offset += try verifyFrame(buf[offset..], 3, 3);    // p50
    offset += try verifyFrame(buf[offset..], 4, 4);    // p99
    offset += try verifyU32Frame(buf[offset..], 5, 5); // active_connections

    // orchestrator 层 (3 帧)
    offset += try verifyFrame(buf[offset..], 6, 10);   // modality_switch
    offset += try verifyFrame(buf[offset..], 7, 20);   // quantize_time
    offset += try verifyFrame(buf[offset..], 8, 30);   // token_count

    // execution 层 (4 帧)
    offset += try verifyFrame(buf[offset..], 9, 100);   // uring_submit
    offset += try verifyFrame(buf[offset..], 10, 100);  // uring_cqe
    offset += try verifyFrame(buf[offset..], 11, 0);    // syscall_fallback
    offset += try verifyFrame(buf[offset..], 12, 0);    // ring_full

    // router 层 (3 帧)
    offset += try verifyFrame(buf[offset..], 13, 50);   // route_hit
    offset += try verifyFrame(buf[offset..], 14, 1);    // route_miss
    offset += try verifyFrame(buf[offset..], 15, 0);    // middleware_reject

    // storage 层 (5 帧)
    offset += try verifyFrame(buf[offset..], 16, 25);   // heat_hit
    offset += try verifyFrame(buf[offset..], 17, 3);    // heat_miss
    offset += try verifyFrame(buf[offset..], 18, 1);    // ssd_flush
    offset += try verifyFrame(buf[offset..], 19, 10);   // vector_search
    offset += try verifyFrame(buf[offset..], 20, 4096); // arena_bytes

    try testing.expectEqual(len, offset);
}

test "P59-4: 零值指标正确编码" {
    ibus.init(); // 所有指标归零

    var buf: [2048]u8 = undefined;
    const len = ibus.formatBinaryMetrics(&buf);
    try testing.expectEqual(@as(usize, 256), len);

    // 验证第一帧的值为 0
    const frame_len = readU32LE(buf[0..4]);
    try testing.expectEqual(@as(u32, 9), frame_len);
    try testing.expectEqual(@as(u8, 1), buf[4]); // field_id = 1
    const val = readU64LE(buf[5..13]);
    try testing.expectEqual(@as(u64, 0), val);
}

test "P59-5: 小缓冲区安全截断" {
    ibus.init();

    // 只给 5 字节缓冲区（不足以写一个完整帧）
    var tiny_buf: [5]u8 = undefined;
    const len = ibus.formatBinaryMetrics(&tiny_buf);
    // 第一个 u64 帧需要 13 字节，5 字节不够，应返回 0
    try testing.expectEqual(@as(usize, 0), len);
}
