const std = @import("std");
const token = @import("token.zig");
const quantizer = @import("quantizer.zig");

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
