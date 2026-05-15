const heap = @import("std").heap;
const token = @import("token.zig");
const quantizer = @import("quantizer.zig");

// C FFI: 真实图像特征提取（使用 extern 声明，image_feature.c 会被链接）
extern fn extract_image_features(path: [*]const u8, output: [*]f32) c_int;

// 模态枚举
pub const Modality = enum {
    Text,
    Image,
    Audio,
    Unknown,
};

// 子脑接口
pub const SubBrain = struct {
    name: []const u8,
    /// 提取连续特征向量，返回维度必须为 dim
    extract: *const fn (input: []const u8, output: []f32) anyerror!void,
    input_modality: Modality,
    dim: u16, // 输出向量维度
};

// 文本直通子脑的 extract（不会被调用，因为文本走直通路径）
fn textExtract(_: []const u8, _: []f32) anyerror!void {
    // 文本直通不需要提取向量
    return error.TextPassthrough;
}

// LCG 随机数生成器（与 quantizer.zig 保持一致）
fn lcgRandom(state: *u32) u32 {
    state.* = state.* *% 1103515245 +% 12345;
    return state.*;
}

// 基于LCG的图像特征提取：输出 output.len 维向量
fn imageExtractLcg(input: []const u8, output: []f32) anyerror!void {
    if (output.len == 0) return error.BufferTooSmall;
    
    // 使用 FNV-1a 哈希生成种子（更好的分布）
    var seed: u32 = 2166136261;
    for (input) |byte| {
        seed = (seed ^ @as(u32, byte)) *% 16777619;
    }
    // 加入长度信息
    seed = (seed ^ @as(u32, @intCast(input.len))) *% 16777619;
    if (seed == 0) seed = 12345;
    
    // 生成 output.len 维特征向量（范围 [-1, 1]）
    var i: usize = 0;
    while (i < output.len) : (i += 1) {
        const rand_val = lcgRandom(&seed);
        // 归一化到 [-1, 1]
        output[i] = (@as(f32, @floatFromInt(rand_val & 0x7FFFFFFF)) / @as(f32, @floatFromInt(0x7FFFFFFF))) * 2.0 - 1.0;
    }
    return;
}

// 获取文本直通子脑（默认注册）
pub fn getTextBrain() SubBrain {
    return SubBrain{
        .name = "text_passthrough",
        .extract = textExtract,
        .input_modality = .Text,
        .dim = 0, // 文本直通不需要向量
    };
}

// 获取LCG图像子脑（64维特征向量，与MAX_TOKEN_DIM一致）
pub fn getImageBrainLcg() SubBrain {
    return SubBrain{
        .name = "image_lcg_64d",
        .extract = imageExtractLcg,
        .input_modality = .Image,
        .dim = 64,
    };
}

// 获取模拟图像子脑（用于测试，2维）
pub fn getImageBrain() SubBrain {
    return SubBrain{
        .name = "image_mock",
        .extract = imageExtractLcg, // 现在也使用LCG，但只填充前2维
        .input_modality = .Image,
        .dim = 2,
    };
}

// 真实图像特征提取：调用 C 的 extract_image_features
fn imageExtractReal(input: []const u8, output: []f32) anyerror!void {
    if (output.len < 64) return error.BufferTooSmall;

    // 将图像路径转为 C 字符串（null-terminated）- Zig 0.16 兼容实现
    // ARCH-2: 使用栈缓冲区替代 page_allocator，零堆分配
    if (input.len + 1 > 4096) return error.PathTooLong;
    var path_buf: [4096]u8 = undefined;
    @memcpy(path_buf[0..input.len], input);
    path_buf[input.len] = 0; // null 终止符
    const path_c = path_buf[0..input.len + 1];

    // 调用 C 函数，获取 64 维特征
    var features: [64]f32 = undefined;
    const rc = extract_image_features(path_c.ptr, &features);
    if (rc != 0) return error.ImageFeatureFailed;

    // 复制到 output
    @memcpy(output[0..64], features[0..64]);
    return;
}

// 获取真实图像子脑（stb_image，64 维）
pub fn getImageBrainReal() SubBrain {
    return SubBrain{
        .name = "image_real_stb",
        .extract = imageExtractReal,
        .input_modality = .Image,
        .dim = 64,
    };
}
