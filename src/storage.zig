// src/storage.zig
// ZigClaw V2.4 | 物理存储池 | 报头生命周期管理 + BodyBufferPool
// 豁免：顶部const std = @import("std")，用于std.mem.readInt类型推导
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

pub const BodyBufferPool = struct {
    buffers: [1024][4096]u8,
    write_offsets: [1024]u32,

    pub fn init() BodyBufferPool {
        return .{
            .buffers = [_][4096]u8{[_]u8{0} ** 4096} ** 1024,
            .write_offsets = [_]u32{0} ** 1024,
        };
    }

    pub fn get_write_slice(self: *BodyBufferPool, stream_id: u64) struct { [*]u8, u32 } {
        const slot_idx = @mod(stream_id, 1024);
        const offset = self.write_offsets[slot_idx];
        return .{ @as([*]u8, @ptrCast(&self.buffers[slot_idx][offset])), offset };
    }

    pub fn advance(self: *BodyBufferPool, stream_id: u64, bytes_written: u32) void {
        const slot_idx = @mod(stream_id, 1024);
        self.write_offsets[slot_idx] += bytes_written;
    }
};
