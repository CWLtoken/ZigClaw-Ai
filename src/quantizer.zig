const math = @import("std").math;
const testing = @import("std").testing;
const token = @import("token.zig");

pub const Quantizer = struct {
    codebook: [256][token.MAX_TOKEN_DIM]f32,
    codebook_len: u16,

    // 初始化量化器（简单确定性码本，用于测试）
    pub fn init() Quantizer {
        var q = Quantizer{
            .codebook = [_][token.MAX_TOKEN_DIM]f32{[_]f32{0} ** token.MAX_TOKEN_DIM} ** 256,
            .codebook_len = 256,
        };

        // 初始化码本：每个码本向量是单位向量 + 偏移
        var i: u16 = 0;
        while (i < 256) : (i += 1) {
            const angle = @as(f32, @floatFromInt(i)) * (2.0 * math.pi / 256.0);
            // 简单初始化：前两个维度用正弦余弦，其余为0
            q.codebook[i][0] = @cos(angle);
            q.codebook[i][1] = @sin(angle);
            var j: u32 = 2;
            while (j < token.MAX_TOKEN_DIM) : (j += 1) {
                q.codebook[i][j] = 0.0;
            }
        }
        return q;
    }

    // 量化：找最近邻码本向量，存储索引+残差
    pub fn quantize(self: *const Quantizer, vector: []const f32, tok: *token.Token) !void {
        if (vector.len == 0) return error.EmptyVector;
        if (vector.len > token.MAX_TOKEN_DIM) return error.VectorTooLarge;

        // 找余弦相似度最高的码本向量
        var best_idx: u16 = 0;
        var best_sim: f32 = -1.0;

        var i: u16 = 0;
        while (i < self.codebook_len) : (i += 1) {
            const sim = cosineSimilarity(vector, self.codebook[i][0..vector.len]);
            if (sim > best_sim) {
                best_sim = sim;
                best_idx = i;
            }
        }

        // 存储码本索引（转为f32）到 data[0]
        tok.data[0] = @floatFromInt(best_idx);
        tok.dim = @intCast(vector.len + 1); // +1 是因为要存索引

        // 计算残差：vector - codebook[best_idx]，存入 data[1..]
        var j: u32 = 0;
        while (j < vector.len) : (j += 1) {
            tok.data[j + 1] = vector[j] - self.codebook[best_idx][j];
        }

        tok.tpe = .VectorQuantized;
    }

    // 反量化：从 token 恢复近似向量
    pub fn dequantize(self: *const Quantizer, tok: *const token.Token, output: []f32) void {
        if (tok.tpe != .VectorQuantized) return;
        if (tok.dim == 0) return;

        // 取码本索引
        const idx = @as(u16, @intFromFloat(tok.data[0]));
        if (idx >= self.codebook_len) return;

        // 输出 = 码本向量 + 残差
        const vec_dim = tok.dim - 1; // 减去索引占用的维度
        var i: u32 = 0;
        while (i < vec_dim and i < output.len and i < token.MAX_TOKEN_DIM) : (i += 1) {
            output[i] = self.codebook[idx][i] + tok.data[i + 1];
        }
    }
};

// 计算余弦相似度
fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    const len = if (a.len < b.len) a.len else b.len;
    if (len == 0) return 0.0;

    var dot: f32 = 0.0;
    var norm_a: f32 = 0.0;
    var norm_b: f32 = 0.0;

    var i: u32 = 0;
    while (i < len) : (i += 1) {
        dot += a[i] * b[i];
        norm_a += a[i] * a[i];
        norm_b += b[i] * b[i];
    }

    const norm_product = @sqrt(norm_a) * @sqrt(norm_b);
    if (norm_product == 0.0) return 0.0;
    return dot / norm_product;
}

// 单元测试：量化反量化一致性
test "Quantizer: 量化反量化一致性" {
    const q = Quantizer.init();
    // 测试向量
    const test_vec = [_]f32{ 0.5, 0.5, 0.0, 0.0 };
    var tok = token.Token.initVector(test_vec[0..]);

    try q.quantize(test_vec[0..], &tok);
    try testing.expect(tok.tpe == .VectorQuantized);

    // 反量化
    var reconstructed: [4]f32 = undefined;
    q.dequantize(&tok, reconstructed[0..]);

    // 计算余弦相似度
    const sim = cosineSimilarity(test_vec[0..], reconstructed[0..]);
    try testing.expect(sim >= 0.92);
}

test "Quantizer: 余弦相似度计算" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 1.0, 0.0, 0.0 };
    const sim = cosineSimilarity(a[0..], b[0..]);
    try testing.expectApproxEqAbs(@as(f32, 1.0), sim, 0.001);
}

// 最小 LCG 随机数生成器（替代 Zig 0.16 缺失的 std.rand 模块）
const Lcg = struct {
    state: u64,

    const MULTIPLIER: u64 = 6364136223846793005;
    const INCREMENT: u64 = 1442695040888963407;

    fn init(seed: u64) Lcg {
        return .{ .state = seed };
    }

    fn next(self: *Lcg) u64 {
        self.state = MULTIPLIER *% self.state +% INCREMENT;
        return self.state;
    }

    /// 返回 [0, 1) 区间的 f32
    fn nextFloat(self: *Lcg) f32 {
        const val = self.next();
        return @as(f32, @floatFromInt(val >> 40)) / @as(f32, @floatFromInt(1 << 24));
    }
};

test "Quantizer: 1000组随机向量，余弦相似度≥0.92" {
    const q = Quantizer.init();
    var rng = Lcg.init(12345);

    var pass_count: u32 = 0;
    const total: u32 = 1000;

    var n: u32 = 0;
    while (n < total) : (n += 1) {
        // 生成随机向量（2维，因为码本只初始化了前2维）
        var vec: [2]f32 = undefined;
        vec[0] = rng.nextFloat() * 2.0 - 1.0; // [-1, 1]
        vec[1] = rng.nextFloat() * 2.0 - 1.0;

        var tok = token.Token.initVector(vec[0..]);
        q.quantize(vec[0..], &tok) catch continue;

        var reconstructed: [2]f32 = undefined;
        q.dequantize(&tok, reconstructed[0..]);

        const sim = cosineSimilarity(vec[0..], reconstructed[0..]);
        if (sim >= 0.92) {
            pass_count += 1;
        }
    }

    const pass_rate = @as(f32, @floatFromInt(pass_count)) / @as(f32, @floatFromInt(total));
    try testing.expect(pass_rate >= 0.92);
}

