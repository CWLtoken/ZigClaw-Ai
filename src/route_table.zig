// src/route_table.zig
// 路由层 | Layer: Router
const router = @import("router.zig");

pub const RouteTable = struct {
    handlers: [256]?router.HandlerFn,

    pub fn init() RouteTable {
        return .{ .handlers = [_]?router.HandlerFn{null} ** 256 };
    }

    pub fn set_handler(self: *RouteTable, op_code: u8, handler: router.HandlerFn) void {
        self.handlers[op_code] = handler;
    }

    pub fn get_handler(self: *const RouteTable, op_code: u8) ?router.HandlerFn {
        return self.handlers[op_code];
    }
};

// 单元测试（P45）
const std = @import("std");

test "P45: RouteTable 初始化全null" {
    const table = RouteTable.init();
    for (0..256) |i| {
        std.debug.assert(table.get_handler(@intCast(i)) == null);
    }
}

test "P45: RouteTable 设置和获取处理器" {
    var table = RouteTable.init();
    const test_handler: router.HandlerFn = struct {
        fn handler(ctx: *router.RequestContext) void {
            _ = ctx;
        }
    }.handler;
    
    table.set_handler(1, test_handler);
    std.debug.assert(table.get_handler(1) != null);
    std.debug.assert(table.get_handler(2) == null);
    std.debug.print("P45: 路由表测试通过\n", .{});
}
