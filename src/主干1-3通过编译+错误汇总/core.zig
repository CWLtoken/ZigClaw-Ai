// src/core.zig
// ZigClaw V2.4 | 核心数据退化协议 | 纯字节数组容器
const std = @import("std");

/// 物理布局：[0..8) stream_id(u64 LE) | [8..12) total_len(u32 LE) | [12] op_code(u8)
pub const TokenStreamHeader = struct {
    data: [13]u8,

    pub fn init() TokenStreamHeader {
        return .{
            .data = [_]u8{0} ** 13,
        };
    }
};
