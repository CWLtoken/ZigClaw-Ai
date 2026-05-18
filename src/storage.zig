// src/storage.zig
// ZigClaw V2.4 | 物理存储池 | 报头生命周期管理 + BodyBufferPool
const mem = @import("std").mem;
const core = @import("core.zig");
const constants = @import("constants.zig");

pub const StreamWindow = struct {
    headers: [constants.SLOT_COUNT]core.TokenStreamHeader,
    len: u64,

    pub fn init() StreamWindow {
        return .{
            .headers = [_]core.TokenStreamHeader{core.TokenStreamHeader.init()} ** constants.SLOT_COUNT,
            .len = 0,
        };
    }

    pub fn push_header(self: *StreamWindow, header: core.TokenStreamHeader) void {
        if (self.len < constants.SLOT_COUNT) {
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

// ============================================================================
// BodyBufferPool — 内存热池
// 与 file_store 的 HeatPool 共享相同的 slot 映射策略
// ============================================================================

pub const BodyBufferPool = struct {
    buffers: [1024][4096]u8,
    write_offsets: [1024]u32,
    // 槽占用位图：每个 u32 管理 32 个槽，共 1024/32 = 32 个 u32
    slot_bitmap_raw: [32]u32,

    pub fn init() BodyBufferPool {
        return .{
            .buffers = [_][4096]u8{[_]u8{0} ** 4096} ** 1024,
            .write_offsets = [_]u32{0} ** 1024,
            .slot_bitmap_raw = [_]u32{0} ** 32,
        };
    }

    /// 分配一个槽位（CAS 原子分配，防止 stream_id 模冲突）
    /// 返回分配的槽索引，若无可用槽返回 null
    /// 显性直白：CAS 重试有上限，失败后直接返回 null（不 fallback 覆盖）
    fn alloc_slot(self: *BodyBufferPool, stream_id: u64) ?u32 {
        const start: u32 = @intCast(stream_id % 1024);
        var i: u32 = 0;
        while (i < 1024) : (i += 1) {
            const slot = (start + i) % 1024;
            const word_idx = slot / 32;
            const bit_idx = slot % 32;
            const bit: u32 = @as(u32, 1) << @intCast(bit_idx);

            // CAS 尝试设置位
            var cas_retries: u32 = 0;
            const MAX_CAS_RETRIES: u32 = 16;
            while (cas_retries < MAX_CAS_RETRIES) : (cas_retries += 1) {
                const old = @atomicLoad(u32, &self.slot_bitmap_raw[word_idx], .acquire);
                if (old & bit != 0) break; // 槽已被占用，尝试下一个
                // SEC-1: 使用 .Or 替代 .Xchg 模拟 CAS，语义更清晰
                const prev = @atomicRmw(u32, &self.slot_bitmap_raw[word_idx], .Or, bit, .acq_rel);
                if (prev & bit == 0) {
                    return slot; // 之前为0，设置成功
                }
                // 已被其他线程设置，retry
            }
        }
        return null; // 所有槽已满
    }

    /// 释放一个槽位
    fn free_slot(self: *BodyBufferPool, slot: u32) void {
        const word_idx = slot / 32;
        const bit_idx = slot % 32;
        const bit: u32 = @as(u32, 1) << @intCast(bit_idx);
        _ = @atomicRmw(u32, &self.slot_bitmap_raw[word_idx], .And, ~bit, .release);
        self.write_offsets[slot] = 0;
    }

    /// 获取写入切片（CAS 分配槽位）
    /// 显性直白：槽满时返回 null，不 fallback 覆盖
    /// SEC-2: 返回 SlotHandle 携带 CAS 分配的槽索引，避免 advance/get_read_slice/reset_slot 用 @mod 重新计算导致不一致
    pub const SlotHandle = struct { slot: u32, offset: u32 };

    pub fn get_write_slice(self: *BodyBufferPool, stream_id: u64) ?struct { [*]u8, SlotHandle } {
        const slot = self.alloc_slot(stream_id) orelse {
            return null; // 槽已满，返回 null（不覆盖）
        };
        const offset = self.write_offsets[slot];
        return .{ @as([*]u8, @ptrCast(&self.buffers[slot][offset])), SlotHandle{ .slot = slot, .offset = offset } };
    }

    /// ⚠️ DES-1: 不安全：直接 @mod 映射，不检查槽占用。仅在线程独占/无冲突场景使用
    pub fn get_write_slice_mod(self: *BodyBufferPool, stream_id: u64) struct { [*]u8, u32 } {
        const slot: u32 = @intCast(stream_id % 1024);
        const offset = self.write_offsets[slot];
        return .{ @as([*]u8, @ptrCast(&self.buffers[slot][offset])), offset };
    }

    /// SEC-2: 使用 SlotHandle 而非 stream_id 重新计算槽索引
    pub fn advance(self: *BodyBufferPool, handle: SlotHandle, bytes_written: u32) void {
        self.write_offsets[handle.slot] += bytes_written;
    }

    /// 获取读取切片（从 0 到当前写入偏移）
    /// SEC-2: 使用 SlotHandle 确保与 CAS 分配的槽一致
    pub fn get_read_slice(self: *BodyBufferPool, handle: SlotHandle, len: u32) []u8 {
        return self.buffers[handle.slot][0..len];
    }

    /// SEC-2: 使用 SlotHandle 而非 stream_id 重新计算槽索引
    pub fn reset_slot(self: *BodyBufferPool, handle: SlotHandle) void {
        self.write_offsets[handle.slot] = 0;
        // 同时释放位图槽
        const word_idx = handle.slot / 32;
        const bit_idx = handle.slot % 32;
        const bit: u32 = @as(u32, 1) << @intCast(bit_idx);
        _ = @atomicRmw(u32, &self.slot_bitmap_raw[word_idx], .And, ~bit, .release);
    }
};
