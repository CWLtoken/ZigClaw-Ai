// src/heat_pool.zig
// 存储层 | Layer: Storage
// 热度池，基于动态分段指数衰减公式

// 精确导入：mem + linux（clock_gettime）+ 共享常量
const mem = @import("std").mem;
const linux = @import("std").os.linux;
const constants = @import("constants.zig");

/// 获取单调时钟纳秒时间戳（用于 last_touch_ns）
fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub const HEAT_POOL_SIZE = constants.SLOT_COUNT; // 与 StreamWindow 容量一致

pub const HeatPool = struct {
    heats: [HEAT_POOL_SIZE]u16,
    last_touch_ns: [HEAT_POOL_SIZE]u64,

    pub fn init() HeatPool {
        return .{
            .heats = [_]u16{0} ** HEAT_POOL_SIZE,
            .last_touch_ns = [_]u64{0} ** HEAT_POOL_SIZE,
        };
    }

    /// 更新指定槽位的热度值，返回新值
    pub fn update_heat(self: *HeatPool, slot: usize, accessed: bool) u16 {
        if (slot >= HEAT_POOL_SIZE) return 0;
        var heat: f32 = @floatFromInt(self.heats[slot]);
        if (accessed) {
            // 更新最后访问时间戳
            self.last_touch_ns[slot] = monotonicNs();
            // 首次访问给基础增量，避免0.xxx截断为0
            if (heat == 0) {
                heat = 100.0;
            } else {
                // 修正：显式转换到 f64 保证精度（Zig 0.16 @log 接受 f64）
                const heat_f64: f64 = @floatCast(heat);
                const updated: f64 = heat_f64 + @log(heat_f64 + 1.5) * 0.75;
                heat = @floatCast(updated);
            }
        } else {
            // 修正：显式转换到 f64 保证精度
            const heat_f64_decay: f64 = @floatCast(heat);
            const dyn_decay: f32 = @floatCast(0.00035 + (0.012 / (heat_f64_decay + 2.0)));
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

    pub fn get_last_touch_ns(self: *const HeatPool, slot: usize) u64 {
        if (slot >= HEAT_POOL_SIZE) return 0;
        return self.last_touch_ns[slot];
    }

    /// 根据经过的时间衰减热度（用于 SSD 恢复时）
    /// elapsed_ns: 从快照到现在经过的纳秒数
    pub fn apply_elapsed_decay(self: *HeatPool, slot: usize, elapsed_ns: u64) u16 {
        if (slot >= HEAT_POOL_SIZE) return 0;
        var heat: f32 = @floatFromInt(self.heats[slot]);
        if (heat <= 0) return 0;
        // 逐秒衰减（最多 300 秒，避免过长循环）
        const max_steps: u32 = @intCast(@min(elapsed_ns / 1_000_000_000, 300));
        var i: u32 = 0;
        while (i < max_steps) : (i += 1) {
            const heat_f64: f64 = @floatCast(heat);
            if (heat_f64 <= 1.0) break;
            const dyn_decay: f32 = @floatCast(0.00035 + (0.012 / (heat_f64 + 2.0)));
            heat *= (1.0 - dyn_decay);
        }
        if (heat > 65535.0) heat = 65535.0;
        self.heats[slot] = @intFromFloat(heat);
        return self.heats[slot];
    }
};

// 单元测试（P42）
const debug = @import("std").debug;
test "P42: HeatPool 初始化全零" {
    const pool = HeatPool.init();
    for (0..HEAT_POOL_SIZE) |i| {
        debug.assert(pool.get_heat(i) == 0);
    }
}

test "P42: HeatPool 更新热度 - 访问递增" {
    var pool = HeatPool.init();
    const slot: usize = 5;
    _ = pool.update_heat(slot, true);
    debug.print("访问后热度: {d}\n", .{pool.get_heat(slot)});
    debug.assert(pool.get_heat(slot) > 0);
}

test "P42: HeatPool 更新热度 - 未访问衰减" {
    var pool = HeatPool.init();
    const slot: usize = 10;
    _ = pool.update_heat(slot, true); // 先访问一次
    const after_access = pool.get_heat(slot);
    _ = pool.update_heat(slot, false); // 未访问，衰减
    const after_decay = pool.get_heat(slot);
    debug.print("衰减前: {d}, 衰减后: {d}\n", .{ after_access, after_decay });
    debug.assert(after_decay <= after_access);
}
