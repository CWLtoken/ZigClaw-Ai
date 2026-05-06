// src/vector_index.zig
// 路由层 | Layer: Router
// 暴力搜索向量索引，余弦相似度

const mem = @import("std").mem;

pub const DIM = 256;
pub const MAX_VECTORS = 64;

pub const VectorIndex = struct {
    vectors: [MAX_VECTORS][DIM]f32,
    keys: [MAX_VECTORS]u64,
    len: u8,

    pub fn init() VectorIndex {
        return .{ 
            .vectors = [_][DIM]f32{[_]f32{0} ** DIM} ** MAX_VECTORS, 
            .keys = [_]u64{0} ** MAX_VECTORS, 
            .len = 0 
        };
    }

    pub fn add(self: *VectorIndex, key: u64, vector: *const [DIM]f32) !void {
        if (self.len >= MAX_VECTORS) return error.Full;
        self.vectors[self.len] = vector.*;
        self.keys[self.len] = key;
        self.len += 1;
    }

    pub fn search(self: *const VectorIndex, query: *const [DIM]f32, top_k: u8) [MAX_VECTORS]u64 {
        var results: [MAX_VECTORS]u64 = undefined;
        // 简单实现：按相似度降序排列，返回 top_k 个键
        var sims: [MAX_VECTORS]f32 = undefined;
        var indices: [MAX_VECTORS]usize = undefined; // 原始索引
        for (0..self.len) |i| {
            sims[i] = cosine_similarity(query, &self.vectors[i]);
            indices[i] = i;
        }
        // 冒泡排序：按相似度降序，同时交换indices
        for (0..self.len) |i| {
            for (i+1..self.len) |j| {
                if (sims[i] < sims[j]) {
                    // 交换相似度
                    const tmp_sim = sims[i]; sims[i] = sims[j]; sims[j] = tmp_sim;
                    // 交换索引
                    const tmp_idx = indices[i]; indices[i] = indices[j]; indices[j] = tmp_idx;
                }
            }
        }
        // 从排序后的indices取top_k个，映射到keys
        const n = @min(top_k, self.len);
        for (0..n) |i| {
            results[i] = self.keys[indices[i]];
        }
        if (n < MAX_VECTORS) {
            @memset(results[n..], 0);
        }
        return results;
    }

    fn cosine_similarity(a: *const [DIM]f32, b: *const [DIM]f32) f32 {
        var dot: f32 = 0;
        var norm_a: f32 = 0;
        var norm_b: f32 = 0;
        for (0..DIM) |i| {
            dot += a[i] * b[i];
            norm_a += a[i] * a[i];
            norm_b += b[i] * b[i];
        }
        const denom_f64: f64 = @sqrt(@as(f64, @floatCast(norm_a * norm_b)));
        const denom: f32 = @floatCast(denom_f64);
        if (denom == 0) return 0;
        return dot / denom;
    }
};

// 单元测试（P44）
const std = @import("std");
const math = std.math;

test "P44: VectorIndex 初始化为空" {
    const index = VectorIndex.init();
    std.debug.assert(index.len == 0);
}

test "P44: VectorIndex 添加向量和搜索" {
    var index = VectorIndex.init();
    var vec1: [DIM]f32 = [_]f32{0} ** DIM;
    vec1[0] = 1.0;
    try index.add(1001, &vec1);
    
    var query: [DIM]f32 = [_]f32{0} ** DIM;
    query[0] = 1.0;
    const results = index.search(&query, 1);
    std.debug.assert(results[0] == 1001);
    std.debug.print("P44: 向量索引测试通过\n", .{});
}
