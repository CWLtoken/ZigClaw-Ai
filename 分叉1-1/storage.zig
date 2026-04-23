// src/storage.zig
// ZigClaw V2.4 | 物理存储池 | 报头生命周期管理 + Phase5 新增BodyBufferPool
// Phase5修正：顶部加const std = @import("std");（遵循豁免模式）
const std = @import("std");
const core = @import("core.zig");

pub const StreamWindow = struct {
    headers: [64]core.TokenStreamHeader,
    len: u64,

    pub fn init() StreamWindow {
        return .{
            .headers = [_]core.TokenStreamHeader{core.TokenStreamHeader.init()} ** 64,
            .len = 0,
        };
    }

    pub fn push_header(self: *StreamWindow, header: core.TokenStreamHeader) void {
        if (self.len < 64) {
            self.headers[self.len] = header;
            self.len += 1;
        }
    }

    // Phase5修正：回退为std.mem.readInt（顶部已const std）
    pub fn access_header(self: *StreamWindow, stream_id: u64) ?*core.TokenStreamHeader {
        for (&self.headers, 0..) |*h, i| {
            if (i < self.len) {
                const id = std.mem.readInt(u64, h.data[0..8], .little);
                if (id == stream_id) return h;
            }
        }
        return null;
    }
};

// ==========================================
// Phase5 新增：真实物理内存池（血肉搬运）
// 严格军规：二维静态数组，无封装，显式全0初始化
// ==========================================
pub const BodyBufferPool = struct {
    // 1024个流，每个流最大4096字节Body，丑陋但真实
    buffers: [1024][4096]u8,
    // 记录每个流当前写入的偏移量
    write_offsets: [1024]u32,

    pub fn init() BodyBufferPool {
        return .{
            // 显式全0初始化，消灭undefined，遵守军规
            .buffers = [_][4096]u8{[_]u8{0} ** 4096} ** 1024,
            .write_offsets = [_]u32{0} ** 1024,
        };
    }

    /// 获取指定流ID的缓冲区基地址和当前偏移量（裸指针返回，无封装）
    pub fn get_write_slice(self: *BodyBufferPool, stream_id: u64) struct { [*]u8, u32 } {
        const slot_idx = @mod(stream_id, 1024);
        const offset = self.write_offsets[slot_idx];
        return .{ &self.buffers[slot_idx][offset], offset };
    }

    /// 搬运完成后推进偏移量（允许覆盖，真实段错误惩罚）
    pub fn advance(self: *BodyBufferPool, stream_id: u64, bytes_written: u32) void {
        const slot_idx = @mod(stream_id, 1024);
        self.write_offsets[slot_idx] += bytes_written;
    }
};