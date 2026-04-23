const std = @import("std");

pub const IBusControlPlane = extern struct {
    latency_context_hash: u64,
    metabolism_valve: u8,
    _pad: [4096 - 8 - 1]u8 = [_]u8{0} ** (4096 - 8 - 1),

    pub fn zero_init() IBusControlPlane {
        return IBusControlPlane{
            .latency_context_hash = 0,
            .metabolism_valve = 1,
        };
    }
};

pub const TokenStreamHeader = extern struct {
    data: [13]u8,

    pub fn init() TokenStreamHeader {
        return TokenStreamHeader{ .data = [_]u8{0} ** 13 };
    }

    pub fn stream_id(self: *const TokenStreamHeader) u64 {
        return std.mem.readInt(u64, self.data[0..8], .little);
    }

    pub fn set_stream_id(self: *TokenStreamHeader, id: u64) void {
        std.mem.writeInt(u64, self.data[0..8], id, .little);
    }

    pub fn total_len(self: *const TokenStreamHeader) u32 {
        return std.mem.readInt(u32, self.data[8..12], .little);
    }

    pub fn set_total_len(self: *TokenStreamHeader, len: u32) void {
        std.mem.writeInt(u32, self.data[8..12], len, .little);
    }

    pub fn flags(self: *const TokenStreamHeader) u8 {
        return self.data[12];
    }

    pub fn set_flags(self: *TokenStreamHeader, f: u8) void {
        self.data[12] = f;
    }
};

pub fn update_heat(current: u16, is_access: bool) u16 {
    if (is_access) return current +| 10;
    return if (current > 0) current - 1 else 0;
}

comptime {
    if (@sizeOf(IBusControlPlane) != 4096) @compileError("ZC-FATAL: IBus must be 4096 bytes");
    if (@sizeOf(TokenStreamHeader) != 13) @compileError("ZC-FATAL: Header must be 13 bytes");
}