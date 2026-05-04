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

// 模拟图像子脑：固定输出向量（用于测试）
fn imageExtract(input: []const u8, output: []f32) anyerror!void {
    _ = input;
    if (output.len < 2) return error.BufferTooSmall;
    // 简单模拟：前两个维度设为固定值
    output[0] = 0.5;
    output[1] = 0.5;
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

// 获取模拟图像子脑（用于测试）
pub fn getImageBrain() SubBrain {
    return SubBrain{
        .name = "image_mock",
        .extract = imageExtract,
        .input_modality = .Image,
        .dim = 2,
    };
}
