// src/route_table.zig
// 路由层 | Layer: Router
// 支持三种匹配策略：exact / prefix / fallback
// 全部静态分配，无堆分配，线性扫描 O(n)，n ≤ 256

const router = @import("router.zig");
const std = @import("std");
const mem = std.mem;

pub const MAX_RULES = 256;

pub const Strategy = enum(u8) {
    exact,
    prefix,
    fallback,
};

pub const RouteRule = struct {
    strategy: Strategy,
    key: [64]u8,
    key_len: u8,
    handler: ?router.HandlerFn,
    weight: u8,
};

pub const RouteTable = struct {
    rules: [MAX_RULES]RouteRule,
    len: u8,

    pub fn init() RouteTable {
        const table: RouteTable = .{
            .rules = [_]RouteRule{.{
                .strategy = .exact,
                .key = [_]u8{0} ** 64,
                .key_len = 0,
                .handler = null,
                .weight = 0,
            }} ** MAX_RULES,
            .len = 0,
        };
        return table;
    }

    pub fn add_rule(self: *RouteTable, strategy: Strategy, key: []const u8, handler: router.HandlerFn, weight: u8) !void {
        if (self.len >= MAX_RULES) return error.Full;
        if (key.len > 64) return error.KeyTooLong;
        var rule = &self.rules[self.len];
        rule.strategy = strategy;
        @memcpy(rule.key[0..key.len], key);
        rule.key_len = @intCast(key.len);
        rule.handler = handler;
        rule.weight = weight;
        self.len += 1;
    }

    pub fn match(self: *const RouteTable, path: []const u8) ?router.HandlerFn {
        var best_weight: u8 = 0;
        var best_handler: ?router.HandlerFn = null;

        for (0..self.len) |i| {
            const rule = &self.rules[i];
            switch (rule.strategy) {
                .exact => {
                    const key = rule.key[0..rule.key_len];
                    if (key.len == path.len and mem.eql(u8, key, path)) {
                        if (rule.weight > best_weight) {
                            best_weight = rule.weight;
                            best_handler = rule.handler;
                        }
                    }
                },
                .prefix => {
                    const key = rule.key[0..rule.key_len];
                    if (path.len >= key.len and mem.eql(u8, path[0..key.len], key)) {
                        if (rule.weight > best_weight) {
                            best_weight = rule.weight;
                            best_handler = rule.handler;
                        }
                    }
                },
                .fallback => {
                    if (rule.weight >= best_weight) {
                        best_weight = rule.weight;
                        best_handler = rule.handler;
                    }
                },
            }
        }
        return best_handler;
    }
};

test "P45: RouteTable 初始化全null" {
    const table = RouteTable.init();
    for (0..MAX_RULES) |_| {
        const result = table.match("any");
        std.debug.assert(result == null);
    }
}

test "P45: RouteTable 设置和获取处理器（精确匹配）" {
    var table = RouteTable.init();
    const test_handler: router.HandlerFn = struct {
        fn handler(ctx: *router.RequestContext) void {
            _ = ctx;
        }
    }.handler;

    try table.add_rule(.exact, "/v1/infer", test_handler, 10);
    std.debug.assert(table.match("/v1/infer") != null);
    std.debug.assert(table.match("/v1/other") == null);
    std.debug.print("P45: 路由表精确匹配测试通过\n", .{});
}
