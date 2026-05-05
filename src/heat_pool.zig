// src/heat_pool.zig
// 存储层 | Layer: Storage
// 热度池，基于动态分段指数衰减公式

const mem = @import("std").mem;

pub const HEAT_POOL_SIZE = 64; // 与 StreamWindow 容量一致

pub const HeatPool = struct {
    heats: [HEAT_POOL_SIZE]u16,

    pub fn init() HeatPool {
        return .{ .heats = [_]u16{0} ** HEAT_POOL_SIZE };
    }

    /// 更新指定槽位的热度值，返回新值
    pub fn update_heat(self: *HeatPool, slot: usize, accessed: bool) u16 {
        if (slot >= HEAT_POOL_SIZE) return 0;
        var heat: f32 = @floatFromInt(self.heats[slot]);
        if (accessed) {
            // 首次访问给基础增量，避免0.xxx截断为0
            if (heat == 0) {
                heat = 100.0;
            } else {
                heat += @log(heat + 1.5) * 0.75;
            }
        } else {
            const dyn_decay = 0.00035 + (0.012 / (heat + 2.0));
            heat *= (1.0 - dyn_decay);
        }
        if (heat > 65535.0) heat = 65535.0;
        self.heats[slot] = @intFromFloat(heat);
        return self.heats[slot];
    }

    pub fn get_heat(self: *const HeatPool, slot: usize) u16 {
        if (slot >= HEAT_POOL_SIZE) return 0;
        return self.heats[slot];
    }
};

// 单元测试（P42）
const std = @import("std");
test "P42: HeatPool 初始化全零" {
    const pool = HeatPool.init();
    for (0..HEAT_POOL_SIZE) |i| {
        std.debug.assert(pool.get_heat(i) == 0);
    }
}

test "P42: HeatPool 更新热度 - 访问递增" {
    var pool = HeatPool.init();
    const slot: usize = 5;
    _ = pool.update_heat(slot, true);
    std.debug.print("访问后热度: {d}\n", .{pool.get_heat(slot)});
    std.debug.assert(pool.get_heat(slot) > 0);
}

test "P42: HeatPool 更新热度 - 未访问衰减" {
    var pool = HeatPool.init();
    const slot: usize = 10;
    _ = pool.update_heat(slot, true); // 先访问一次
    const after_access = pool.get_heat(slot);
    _ = pool.update_heat(slot, false); // 未访问，衰减
    const after_decay = pool.get_heat(slot);
    std.debug.print("衰减前: {d}, 衰减后: {d}\n", .{ after_access, after_decay });
    std.debug.assert(after_decay <= after_access);
}
