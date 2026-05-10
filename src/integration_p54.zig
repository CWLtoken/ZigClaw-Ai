// src/integration_p54.zig
// DRD-057: V2 向量索引增强 — IVF+PQ 集成测试
// 测试策略：
//   1. add + search 有效性
//   2. PQ 量化可逆性 (MSE < 0.1)
//   3. 容量限制 (MAX_VECTORS)

const vi = @import("vector_index.zig");
const DIM = vi.DIM;
const MAX_VECTORS = vi.MAX_VECTORS;

// ============================================================================
// 测试 1: add + search 有效性
// 添加 4 个已知向量，搜索时能准确返回最近邻
// ============================================================================

test "P54-1: add + search 有效性 — 4个已知向量精确检索" {
    var index = vi.VectorIndex.init();

    // 构造 4 个正交基向量（确保各自独立可区分）
    var v0: [DIM]f32 = [_]f32{0} ** DIM;
    v0[0] = 1.0;  // 基向量沿维度 0

    var v1: [DIM]f32 = [_]f32{0} ** DIM;
    v1[50] = 1.0; // 基向量沿维度 50

    var v2: [DIM]f32 = [_]f32{0} ** DIM;
    v2[100] = 1.0; // 基向量沿维度 100

    var v3: [DIM]f32 = [_]f32{0} ** DIM;
    v3[200] = 1.0; // 基向量沿维度 200

    // 添加 4 个向量
    try index.add(100, &v0);
    try index.add(200, &v1);
    try index.add(300, &v2);
    try index.add(400, &v3);

    @import("std").debug.assert(index.len == 4);

    // 搜索与 v0 完全一致的查询
    var q0: [DIM]f32 = [_]f32{0} ** DIM;
    q0[0] = 1.0;
    const results0 = index.search(&q0, 4);
    @import("std").debug.assert(results0[0] == 100); // 最近邻必须是 v0

    // 搜索与 v2 完全一致的查询
    var q2: [DIM]f32 = [_]f32{0} ** DIM;
    q2[100] = 1.0;
    const results2 = index.search(&q2, 4);
    @import("std").debug.assert(results2[0] == 300); // 最近邻必须是 v2

    // 搜索与 v3 完全一致的查询
    var q3: [DIM]f32 = [_]f32{0} ** DIM;
    q3[200] = 1.0;
    const results3 = index.search(&q3, 4);
    @import("std").debug.assert(results3[0] == 400); // 最近邻必须是 v3

    @import("std").debug.print("P54-1: add + search 有效性 通过\n", .{});
}

// ============================================================================
// 测试 2: PQ 量化可逆性
// 验证原始向量与 PQ 压缩再解压的向量之间 MSE < 0.1
// ============================================================================

test "P54-2: PQ 量化可逆性 — MSE < 0.1" {
    var index = vi.VectorIndex.init();

    // 添加 KSUB+1 个向量以触发 PQ 训练
    // 使用结构化向量（非正交，更接近实际情况）
    var vecs: [16][DIM]f32 = undefined;
    for (&vecs, 0..) |*v, i| {
        v.* = [_]f32{0} ** DIM;
        // 每个向量在特定区域有值
        const base = @as(f32, @floatFromInt(i * 16));
        for (0..16) |j| {
            const idx = (i * 16 + j) % DIM;
            v.*[idx] = base + @as(f32, @floatFromInt(j)) * 0.1;
        }
    }

    for (&vecs, 0..) |*v, i| {
        const key: u64 = @intCast(1000 + i);
        try index.add(key, v);
    }

    // PQ 应该已训练
    @import("std").debug.assert(index.pq_trained);

    // 计算每个向量的 PQ 重建误差
    var total_mse: f32 = 0;
    const M_val = 8;     // PQ 子空间数
    const DSUB_val = 32; // 子空间维度

    for (0..16) |v_idx| {
        var recon: [DIM]f32 = [_]f32{0} ** DIM;
        // 用 PQ 码本重建向量
        for (0..M_val) |m| {
            const code = index.pq_codes[v_idx][m];
            const offset = m * DSUB_val;
            for (0..DSUB_val) |d| {
                recon[offset + d] = index.pq_codebooks[m][code][d];
            }
        }

        // 计算 MSE
        var mse: f32 = 0;
        for (0..DIM) |d| {
            const diff = index.vectors[v_idx][d] - recon[d];
            mse += diff * diff;
        }
        mse /= @as(f32, @floatFromInt(DIM));
        total_mse += mse;
    }

    total_mse /= 16.0; // 平均 MSE

    @import("std").debug.print("P54-2: 平均 MSE = {d:.6}\n", .{total_mse});
    @import("std").debug.assert(total_mse < 0.1);

    @import("std").debug.print("P54-2: PQ 量化可逆性 通过\n", .{});
}

// ============================================================================
// 测试 3: 容量限制
// 添加 MAX_VECTORS 个向量后，继续添加返回 error.Full
// ============================================================================

test "P54-3: 容量限制 — MAX_VECTORS 满后返回 Full" {
    var index = vi.VectorIndex.init();

    // 添加 MAX_VECTORS 个向量
    var v: [DIM]f32 = [_]f32{0} ** DIM;
    for (0..MAX_VECTORS) |i| {
        v[0] = @as(f32, @floatFromInt(i));
        const key: u64 = @intCast(5000 + i);
        try index.add(key, &v);
    }

    @import("std").debug.assert(index.len == MAX_VECTORS);

    // 再添加一个应该返回 error.Full
    v[0] = 999.0;
    const result = index.add(9999, &v);
    @import("std").debug.assert(result == error.Full);

    @import("std").debug.print("P54-3: 容量限制 通过\n", .{});
}
