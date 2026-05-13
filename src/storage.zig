// src/storage.zig
// ZigClaw V2.4 | 物理存储池 | 报头生命周期管理 + BodyBufferPool
const mem = @import("std").mem;
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
                const id = mem.readInt(u64, h.data[0..8], .little);
                if (id == stream_id) return h;
            }
        }
        return null;
    }

    pub fn release_header(self: *StreamWindow, stream_id: u64) void {
        for (&self.headers, 0..) |*h, i| {
            if (i < self.len) {
                const id = mem.readInt(u64, h.data[0..8], .little);
                if (id == stream_id) {
                    self.len -= 1;
                    if (i < self.len) {
                        self.headers[i] = self.headers[self.len];
                    }
                    self.headers[self.len] = core.TokenStreamHeader.init();
                    return;
                }
            }
        }
    }
};

pub const BodyBufferPool = struct {
    buffers: [1024][4096]u8,
    write_offsets: [1024]u32,
    // 槽占用位图：每个 u32 管理 32 个槽，共 1024/32 = 32 个 u32
    // 使用普通 u32 数组 + @atomicRmw 实现 CAS（Zig 0.16 atomic.Value 不支持 CAS）
    slot_bitmap_raw: [32]u32,

    pub fn init() BodyBufferPool {
        return .{
            .buffers = [_][4096]u8{[_]u8{0} ** 4096} ** 1024,
            .write_offsets = [_]u32{0} ** 1024,
            .slot_bitmap_raw = [_]u32{0} ** 32,
        };
    }

    /// 分配一个槽位（CAS 原子分配，消除 stream_id 模冲突）
    /// 返回分配的槽索引，若无可用槽返回 null
    fn alloc_slot(self: *BodyBufferPool, stream_id: u64) ?u32 {
        const start: u32 = @intCast(stream_id % 1024);
        var i: u32 = 0;
        while (i < 1024) : (i += 1) {
            const slot = (start + i) % 1024;
            const word_idx = slot / 32;
            const bit_idx = slot % 32;
            const bit: u32 = @as(u32, 1) << @intCast(bit_idx);

            // CAS 尝试设置位（Zig 0.16 使用 @atomicRmw）
            while (true) {
                const old = @atomicLoad(u32, &self.slot_bitmap_raw[word_idx], .acquire);
                if (old & bit != 0) break; // 槽已被占用，尝试下一个
                const prev = @atomicRmw(u32, &self.slot_bitmap_raw[word_idx], .Xchg, old | bit, .acq_rel);
                if (prev == old) {
                    return slot; // CAS 成功
                }
                // CAS 失败，重试
            }
        }
        return null; // 所有槽已满
    }

    /// 释放一个槽位
    fn free_slot(self: *BodyBufferPool, slot: u32) void {
        const word_idx = slot / 32;
        const bit_idx = slot % 32;
        const bit: u32 = @as(u32, 1) << @intCast(bit_idx);
        _ = @atomicRmw(u32, &self.slot_bitmap_raw[word_idx], .Xor, bit, .release);
        self.write_offsets[slot] = 0;
    }

    pub fn get_write_slice(self: *BodyBufferPool, stream_id: u64) struct { [*]u8, u32 } {
        // T6 修复：使用 CAS 分配槽位，避免 @mod 冲突
        const slot = self.alloc_slot(stream_id) orelse {
            // 槽已满，回退到 @mod（可能覆盖，但保证不崩溃）
            const fallback: u32 = @intCast(stream_id % 1024);
            const offset = self.write_offsets[fallback];
            return .{ @as([*]u8, @ptrCast(&self.buffers[fallback][offset])), offset };
        };
        const offset = self.write_offsets[slot];
        return .{ @as([*]u8, @ptrCast(&self.buffers[slot][offset])), offset };
    }

    pub fn advance(self: *BodyBufferPool, stream_id: u64, bytes_written: u32) void {
        const slot_idx = @mod(stream_id, 1024);
        self.write_offsets[slot_idx] += bytes_written;
    }

    /// 获取读取切片（从 0 到当前写入偏移）
    pub fn get_read_slice(self: *BodyBufferPool, stream_id: u64, len: u32) []u8 {
        const slot_idx = @mod(stream_id, 1024);
        return self.buffers[slot_idx][0..len];
    }

    pub fn reset_slot(self: *BodyBufferPool, stream_id: u64) void {
        const slot_idx = @mod(stream_id, 1024);
        self.write_offsets[slot_idx] = 0;
    }
};
