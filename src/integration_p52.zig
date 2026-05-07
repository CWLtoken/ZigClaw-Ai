// src/integration_p52.zig
// P52: 路由增强测试 — 多策略路由（exact / prefix / fallback）

const std = @import("std");
const route_table = @import("route_table.zig");
const router = @import("router.zig");
const mem = std.mem;

// 测试用 handler
fn testHandlerA(ctx: *router.RequestContext) void { _ = ctx; }
fn testHandlerB(ctx: *router.RequestContext) void { _ = ctx; }
fn testHandlerC(ctx: *router.RequestContext) void { _ = ctx; }

test "P52: 精确匹配 — 注册 exact 规则匹配 /v1/infer" {
    var table = route_table.RouteTable.init();

    const handler_a: router.HandlerFn = testHandlerA;
    const handler_b: router.HandlerFn = testHandlerB;

    try table.add_rule(.exact, "/v1/infer", handler_a, 10);
    try table.add_rule(.exact, "/health", handler_b, 5);

    // 精确匹配 /v1/infer
    const result = table.match("/v1/infer");
    std.debug.assert(result != null);
    std.debug.assert(result.? == handler_a);

    // 精确匹配 /health
    const result2 = table.match("/health");
    std.debug.assert(result2 != null);
    std.debug.assert(result2.? == handler_b);

    // 不匹配
    std.debug.assert(table.match("/v1/other") == null);
    std.debug.assert(table.match("/v1/infer/") == null);  // 尾部斜杠不匹配

    std.debug.print("P52: 精确匹配测试通过\n", .{});
}

test "P52: 前缀匹配 — 注册 prefix 规则匹配 /v1/" {
    var table = route_table.RouteTable.init();

    const handler_a: router.HandlerFn = testHandlerA;
    const handler_b: router.HandlerFn = testHandlerB;

    try table.add_rule(.prefix, "/v1/", handler_a, 10);
    try table.add_rule(.exact, "/health", handler_b, 5);

    // 前缀匹配：/v1/infer 以 /v1/ 开头
    const result = table.match("/v1/infer");
    std.debug.assert(result != null);
    std.debug.assert(result.? == handler_a);

    // 前缀匹配：/v1/health 也以 /v1/ 开头
    const result2 = table.match("/v1/health");
    std.debug.assert(result2 != null);
    std.debug.assert(result2.? == handler_a);

    // 精确匹配 /health 仍然有效
    const result3 = table.match("/health");
    std.debug.assert(result3 != null);
    std.debug.assert(result3.? == handler_b);

    // 不匹配
    std.debug.assert(table.match("/api/test") == null);

    std.debug.print("P52: 前缀匹配测试通过\n", .{});
}

test "P52: Fallback — 无匹配时使用 fallback 规则" {
    var table = route_table.RouteTable.init();

    const handler_a: router.HandlerFn = testHandlerA;
    const handler_fallback: router.HandlerFn = testHandlerC;

    // 注册一个 fallback（权重 1，高于默认的 0）
    try table.add_rule(.fallback, "", handler_fallback, 1);
    // 注册一个精确匹配
    try table.add_rule(.exact, "/v1/infer", handler_a, 10);

    // 匹配到精确规则
    const result = table.match("/v1/infer");
    std.debug.assert(result != null);
    std.debug.assert(result.? == handler_a);

    // 未匹配到任何规则，使用 fallback
    const result2 = table.match("/unknown/path");
    std.debug.assert(result2 != null);
    std.debug.assert(result2.? == handler_fallback);

    std.debug.print("P52: Fallback 测试通过\n", .{});
}
