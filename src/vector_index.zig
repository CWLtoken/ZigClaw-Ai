// src/vector_index.zig
// 路由层 | Layer: Router
// IVF + PQ 混合向量索引
// DRD-057: 暴力搜索 → IVF (Inverted File) + PQ (Product Quantization)
//
// 架构约束：
//   - 所有数据结构静态数组，零堆分配
//   - 公开 API add / search 签名不变
//   - 仅用 Zig 内置 @sqrt 和 f32 运算

const mem = @import("std").mem;
const math = @import("std").math;

// ============================================================================
// 常量定义
// ============================================================================

pub const DIM = 256;
pub const MAX_VECTORS = 64;

const NLIST = 4;                      // 粗聚类中心数（倒排桶数）
const M = 8;                           // PQ 子空间数
const KSUB = 16;                       // 每个子空间的聚类中心数
const DSUB = DIM / M;                  // 每个子空间的维度 (256/8 = 32)
const MAX_VECTORS_PER_LIST = MAX_VECTORS; // 每个倒排桶的最大容量
const NPROBE = 1;                      // 搜索时探测的桶数
const KMEANS_ITERS = 10;               // K-Means 最大迭代次数

// ============================================================================
// 静态数据结构
// ============================================================================

pub const VectorIndex = struct {
    // 粗量化器
    centroids: [NLIST][DIM]f32,
    // 倒排列表
    inverted_lists: [NLIST][MAX_VECTORS_PER_LIST]u32,  // 存储向量原始索引
    list_lens: [NLIST]u8,
    // PQ 码本
    pq_codebooks: [M][KSUB][DSUB]f32,
    // 原始向量存储
    vectors: [MAX_VECTORS][DIM]f32,
    keys: [MAX_VECTORS]u64,
    pq_codes: [MAX_VECTORS][M]u8,       // 每个向量的 PQ 编码（每子空间 1 byte）
    len: u8,

    // 训练状态
    pq_trained: bool,
    ivf_initialized: bool,

    pub fn init() VectorIndex {
        return .{
            .centroids   = [_][DIM]f32{[_]f32{0} ** DIM} ** NLIST,
            .inverted_lists = [_][MAX_VECTORS_PER_LIST]u32{[_]u32{0} ** MAX_VECTORS_PER_LIST} ** NLIST,
            .list_lens   = [_]u8{0} ** NLIST,
            .pq_codebooks = [_][KSUB][DSUB]f32{[_][DSUB]f32{[_]f32{0} ** DSUB} ** KSUB} ** M,
            .vectors     = [_][DIM]f32{[_]f32{0} ** DIM} ** MAX_VECTORS,
            .keys        = [_]u64{0} ** MAX_VECTORS,
            .pq_codes    = [_][M]u8{[_]u8{0} ** M} ** MAX_VECTORS,
            .len         = 0,
            .pq_trained  = false,
            .ivf_initialized = false,
        };
    }

    // ========================================================================
    // 公开 API：add
    // ========================================================================

    pub fn add(self: *VectorIndex, key: u64, vector: *const [DIM]f32) !void {
        if (self.len >= MAX_VECTORS) return error.Full;

        const idx = self.len;

        // 存储原始向量
        self.vectors[idx] = vector.*;
        self.keys[idx] = key;

        // 先递增 len，使训练函数能访问当前所有向量（包括刚存的）
        self.len += 1;

        // 增量训练：当积累够 NLIST 个向量时初始化 IVF，达到更多时训练 PQ
        if (self.len >= NLIST) {
            if (!self.ivf_initialized) {
                self.train_ivf();
                self.ivf_initialized = true;
            } else {
                self.train_ivf();
            }

            if (self.len >= KSUB and !self.pq_trained) {
                self.train_pq();
                self.pq_trained = true;
            }
        }

        // PQ 已训练但本轮未重训（len > KSUB），对新向量单独编码
        if (self.pq_trained and self.len > KSUB) {
            var code: [M]u8 = [_]u8{0} ** M;
            self.encode_pq(&self.vectors[idx], &code);
            self.pq_codes[idx] = code;
        }
    }

    // ========================================================================
    // 公开 API：search
    // ========================================================================

    pub fn search(self: *const VectorIndex, query: *const [DIM]f32, top_k: u8) [MAX_VECTORS]u64 {
        var results: [MAX_VECTORS]u64 = [_]u64{0} ** MAX_VECTORS;
        @memset(&results, 0);

        if (self.len == 0) return results;

        // 如果 IVF 未初始化（向量数 < NLIST），回退到暴力搜索
        if (!self.ivf_initialized) {
            return self.brute_search(query, top_k);
        }

        // 1. 粗量化：找到 nprobe 个最近桶
        var probe_dists: [NLIST]f32 = [_]f32{0} ** NLIST;
        var probe_ids: [NLIST]usize = [_]usize{0} ** NLIST;
        for (0..NLIST) |i| {
            probe_dists[i] = sq_euclidean(query, &self.centroids[i]);
            probe_ids[i] = i;
        }
        // 冒泡排序（按距离升序）
        for (0..NLIST) |i| {
            for (i + 1..NLIST) |j| {
                if (probe_dists[i] > probe_dists[j]) {
                    const td = probe_dists[i]; probe_dists[i] = probe_dists[j]; probe_dists[j] = td;
                    const ti = probe_ids[i]; probe_ids[i] = probe_ids[j]; probe_ids[j] = ti;
                }
            }
        }

        // 2. 在 nprobe 个桶内做 PQ 近似距离搜索
        var best_sims: [MAX_VECTORS]f32 = [_]f32{0} ** MAX_VECTORS;
        var best_keys: [MAX_VECTORS]u64 = [_]u64{0} ** MAX_VECTORS;
        var count: u8 = 0;

        for (0..NPROBE) |p| {
            const list_id = probe_ids[p];
            // P2-002: 边界校验 - 防止 list_id 越界
            if (list_id >= NLIST) continue;
            for (0..self.list_lens[list_id]) |j| {
                const vec_idx = self.inverted_lists[list_id][j];
                // P2-002: 边界校验 - 防止 vec_idx 越界
                if (vec_idx >= self.len) continue;
                const key = self.keys[vec_idx];

                var sim: f32 = 0;
                if (self.pq_trained) {
                    var pq_buf: [M]u8 = [_]u8{0} ** M;
                    self.encode_pq_into(query, &pq_buf);
                    sim = self.pq_asymmetric_distance(query, &self.pq_codes[vec_idx]);
                } else {
                    sim = cosine_similarity(query, &self.vectors[vec_idx]);
                }

                if (count < MAX_VECTORS) {
                    best_sims[count] = sim;
                    best_keys[count] = key;
                    count += 1;
                }
            }
        }

        if (count == 0) return results;

        // 3. 按相似度降序排序
        const n = @min(top_k, count);
        for (0..count) |i| {
            for (i + 1..count) |j| {
                if (best_sims[i] < best_sims[j]) {
                    const ts = best_sims[i]; best_sims[i] = best_sims[j]; best_sims[j] = ts;
                    const tk = best_keys[i]; best_keys[i] = best_keys[j]; best_keys[j] = tk;
                }
            }
        }

        for (0..n) |i| {
            results[i] = best_keys[i];
        }

        return results;
    }

    // ========================================================================
    // 暴力搜索（IVF 未初始化时的回退）
    // ========================================================================

    fn brute_search(self: *const VectorIndex, query: *const [DIM]f32, top_k: u8) [MAX_VECTORS]u64 {
        var results: [MAX_VECTORS]u64 = [_]u64{0} ** MAX_VECTORS;
        @memset(&results, 0);

        var sims: [MAX_VECTORS]f32 = [_]f32{0} ** MAX_VECTORS;
        var idxs: [MAX_VECTORS]usize = [_]usize{0} ** MAX_VECTORS;
        for (0..self.len) |i| {
            sims[i] = cosine_similarity(query, &self.vectors[i]);
            idxs[i] = i;
        }
        for (0..self.len) |i| {
            for (i + 1..self.len) |j| {
                if (sims[i] < sims[j]) {
                    const ts = sims[i]; sims[i] = sims[j]; sims[j] = ts;
                    const ti = idxs[i]; idxs[i] = idxs[j]; idxs[j] = ti;
                }
            }
        }
        const n = @min(top_k, self.len);
        for (0..n) |i| {
            results[i] = self.keys[idxs[i]];
        }
        return results;
    }

    // ========================================================================
    // IVF 训练（K-Means 聚类）
    // ========================================================================

    fn train_ivf(self: *VectorIndex) void {
        // 初始化中心点：取前 NLIST 个向量作为初始中心
        for (0..NLIST) |c| {
            if (c < self.len) {
                self.centroids[c] = self.vectors[c];
            }
        }

        // K-Means 迭代
        var assignments: [MAX_VECTORS]u8 = [_]u8{0} ** MAX_VECTORS;
        for (0..KMEANS_ITERS) |_| {
            // 分配步骤：每个向量分配到最近的中心点
            for (0..self.len) |v| {
                var best_d: f32 = sq_euclidean(&self.vectors[v], &self.centroids[0]);
                var best_c: u8 = 0;
                for (1..NLIST) |c| {
                    const d = sq_euclidean(&self.vectors[v], &self.centroids[c]);
                    if (d < best_d) {
                        best_d = d;
                        // P2-003: @intCast 前校验范围（c < NLIST <= 255，u8 安全）
                        best_c = if (c <= 255) @intCast(c) else 0;
                    }
                }
                assignments[v] = best_c;
            }

            // 更新步骤：重新计算中心点
            var sums: [NLIST][DIM]f32 = [_][DIM]f32{[_]f32{0} ** DIM} ** NLIST;
            for (0..NLIST) |c| {
                sums[c] = [_]f32{0} ** DIM;
            }
            var counts: [NLIST]usize = [_]usize{0} ** NLIST;
            @memset(&counts, 0);
            for (0..self.len) |v| {
                const c = assignments[v];
                for (0..DIM) |d| {
                    sums[c][d] += self.vectors[v][d];
                }
                counts[c] = counts[c] + 1;
            }
            for (0..NLIST) |c| {
                if (counts[c] > 0) {
                    for (0..DIM) |d| {
                        self.centroids[c][d] = sums[c][d] / @as(f32, @floatFromInt(counts[c]));
                    }
                }
            }
        }

        // 清空倒排列表后重新分配
        self.list_lens = [_]u8{0} ** NLIST;
        for (&self.inverted_lists) |*list| {
            list.* = [_]u32{0} ** MAX_VECTORS_PER_LIST;
        }
        for (0..self.len) |v| {
            const cq = self.classify_query(&self.vectors[v]);
            if (self.list_lens[cq] < MAX_VECTORS_PER_LIST) {
                self.inverted_lists[cq][self.list_lens[cq]] = @intCast(v);
                self.list_lens[cq] += 1;
            }
        }
    }

    // ========================================================================
    // 粗量化：找到最近的桶
    // ========================================================================

    fn classify_query(self: *const VectorIndex, query: *const [DIM]f32) u8 {
        var best_d = sq_euclidean(query, &self.centroids[0]);
        var best_c: u8 = 0;
        for (1..NLIST) |c| {
            const d = sq_euclidean(query, &self.centroids[c]);
            if (d < best_d) {
                best_d = d;
                best_c = @intCast(c);
            }
        }
        return best_c;
    }

    // ========================================================================
    // PQ 训练（对每个子空间独立做 K-Means）
    // ========================================================================

    fn train_pq(self: *VectorIndex) void {
        for (0..M) |m| {
            const offset = m * DSUB;
            // 初始化码本中心：取前 KSUB 个向量的对应子空间
            for (0..KSUB) |k| {
                var v_idx: usize = k;
                if (v_idx >= self.len) v_idx = self.len - 1;
                for (0..DSUB) |d| {
                    self.pq_codebooks[m][k][d] = self.vectors[v_idx][offset + d];
                }
            }

            // K-Means 迭代
            var assignments: [MAX_VECTORS]u8 = [_]u8{0} ** MAX_VECTORS;
            for (0..KMEANS_ITERS) |_| {
                // 分配
                for (0..self.len) |v| {
                    var best_d: f32 = sq_euclidean_sub(
                        &self.vectors[v], offset,
                        &self.pq_codebooks[m][0],
                    );
                    var best_k: u8 = 0;
                    for (1..KSUB) |k| {
                        const d = sq_euclidean_sub(
                            &self.vectors[v], offset,
                            &self.pq_codebooks[m][k],
                        );
                        if (d < best_d) {
                            best_d = d;
                            // P2-003: @intCast 前校验范围（k < KSUB <= 255，u8 安全）
                            best_k = if (k <= 255) @intCast(k) else 0;
                        }
                    }
                    assignments[v] = best_k;
                }

                // 更新
                var sums: [KSUB][DSUB]f32 = [_][DSUB]f32{[_]f32{0} ** DSUB} ** KSUB;
                for (0..KSUB) |k| {
                    sums[k] = [_]f32{0} ** DSUB;
                }
                var counts: [KSUB]usize = [_]usize{0} ** KSUB;
                @memset(&counts, 0);
                for (0..self.len) |v| {
                    const k = assignments[v];
                    for (0..DSUB) |d| {
                        sums[k][d] += self.vectors[v][offset + d];
                    }
                    counts[k] = counts[k] + 1;
                }
                for (0..KSUB) |k| {
                    if (counts[k] > 0) {
                        for (0..DSUB) |d| {
                            self.pq_codebooks[m][k][d] =
                                sums[k][d] / @as(f32, @floatFromInt(counts[k]));
                        }
                    }
                }
            }
        }

        // 对所有已存储向量编码
        for (0..self.len) |v| {
            self.encode_pq(&self.vectors[v], &self.pq_codes[v]);
        }
    }

    // ========================================================================
    // PQ 编码
    // ========================================================================

    fn encode_pq(self: *const VectorIndex, vector: *const [DIM]f32, code: *[M]u8) void {
        for (0..M) |m| {
            const offset = m * DSUB;
            var best_d = sq_euclidean_sub(
                vector, offset,
                &self.pq_codebooks[m][0],
            );
            var best_k: u8 = 0;
            for (1..KSUB) |k| {
                const d = sq_euclidean_sub(
                    vector, offset,
                    &self.pq_codebooks[m][k],
                );
                if (d < best_d) {
                    best_d = d;
                    // P2-003: @intCast 前校验范围
                    best_k = if (k <= 255) @intCast(k) else 0;
                }
            }
            code[m] = best_k;
        }
    }

    // encode_pq 的编译期版本（用于 search 中 query 的编码）
    fn encode_pq_into(self: *const VectorIndex, vector: *const [DIM]f32, code: *[M]u8) void {
        self.encode_pq(vector, code);
    }

    // ========================================================================
    // PQ 非对称距离计算（ADC）
    // PQ 非对称距离计算（ADC）
    // 返回：近似余弦相似度（越大越相似）
    // ========================================================================
    fn pq_asymmetric_distance(self: *const VectorIndex, query: *const [DIM]f32, vec_code: *const [M]u8) f32 {
        var dist_sq: f32 = 0;
        for (0..M) |m| {
            const offset = m * DSUB;
            const vc = vec_code[m];
            for (0..DSUB) |d| {
                const diff = query[offset + d] - self.pq_codebooks[m][vc][d];
                dist_sq += diff * diff;
            }
        }
        // 转换为相似度：距离越小越相似
        return -dist_sq;
    }

    // ========================================================================
    // 工具函数
    // ========================================================================

    fn sq_euclidean(a: *const [DIM]f32, b: *const [DIM]f32) f32 {
        var sum: f32 = 0;
        for (0..DIM) |i| {
            const diff = a[i] - b[i];
            sum += diff * diff;
        }
        return sum;
    }

    fn sq_euclidean_sub(a: *const [DIM]f32, a_off: usize, b: *const [DSUB]f32) f32 {
        var sum: f32 = 0;
        for (0..DSUB) |i| {
            const diff = a[a_off + i] - b[i];
            sum += diff * diff;
        }
        return sum;
    }
};

// ============================================================================
// 工具函数（模块级）
// ============================================================================

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

// ============================================================================
// 单元测试（P44）
// ============================================================================

const debug = @import("std").debug;

test "P44: VectorIndex 初始化为空" {
    const index = VectorIndex.init();
    debug.assert(index.len == 0);
}

test "P44: VectorIndex 添加向量和搜索" {
    var index = VectorIndex.init();
    var vec1: [DIM]f32 = [_]f32{0} ** DIM;
    vec1[0] = 1.0;
    try index.add(1001, &vec1);

    var query: [DIM]f32 = [_]f32{0} ** DIM;
    query[0] = 1.0;
    const results = index.search(&query, 1);
    debug.assert(results[0] == 1001);
    debug.print("P44: 向量索引测试通过\n", .{});
}
