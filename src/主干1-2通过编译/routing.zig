const core = @import("core.zig");

pub const SLOT_COUNT: usize = 256;
const MASK: usize = SLOT_COUNT - 1;

pub const HashRouter = struct {
    pub fn init() HashRouter {
        return HashRouter{};
    }

    pub fn get_slot(_: *const HashRouter, control_plane: *const core.IBusControlPlane) u8 {
        const hash = control_plane.latency_context_hash;
        return @as(u8, @truncate(hash & MASK));
    }

    pub fn rehash(_: *const HashRouter, old_slot: u8) u8 {
        return old_slot;
    }
};

comptime {
    if ((SLOT_COUNT & (SLOT_COUNT - 1)) != 0) @compileError("ZC-FATAL: SLOT_COUNT power of 2");
    if (SLOT_COUNT > 256) @compileError("ZC-FATAL: SLOT_COUNT <= 256");
    if (@sizeOf(HashRouter) != 0) @compileError("ZC-FATAL: zero-sized router required");
}