// src/entry/app_router.zig
// P2-3: 具体业务路由配置
// 依赖 comptime_router.zig 通用框架，定义本服务的路由表

const std = @import("std");
const comptime_router = @import("../comptime_router.zig");
const RouteContext = comptime_router.RouteContext;
const Route = comptime_router.Route;
const ComptimeRouter = comptime_router.ComptimeRouter;

// ============================================================================
// 业务路由处理函数
// ============================================================================

fn handleText(ctx: *RouteContext) void {
    std.log.info("[AppRouter] TEXT handler, req_id={d}", .{ctx.req_id});
    // 实际项目中调用编排层处理文本推理
}

fn handleImage(ctx: *RouteContext) void {
    std.log.info("[AppRouter] IMAGE handler, req_id={d}", .{ctx.req_id});
    // 实际项目中调用编排层处理图像推理
}

fn handleHealth(ctx: *RouteContext) void {
    std.log.info("[AppRouter] HEALTH handler, req_id={d}", .{ctx.req_id});
    // 实际项目中返回健康检查结果
}

// ============================================================================
// 编译期实例化路由表
// ============================================================================

pub const app_router = ComptimeRouter(&.{
    .{ .op_code = 1, .handler = handleText },
    .{ .op_code = 2, .handler = handleImage },
    .{ .op_code = 3, .handler = handleHealth },
    // 未来加路由，只在这里加一行，零运行时开销
});

// ============================================================================
// 对外暴露的调用入口
// ============================================================================

pub fn routeRequest(op_code: u16, ctx: *RouteContext) void {
    app_router.dispatch(op_code, ctx);
}

// ============================================================================
// 集成测试
// ============================================================================

test "AppRouter: dispatch 不崩溃" {
    var ctx = RouteContext{ .req_id = 1, .modality = 0 };

    // 测试每个已注册的路由
    routeRequest(1, &ctx); // TEXT
    routeRequest(2, &ctx); // IMAGE
    routeRequest(3, &ctx); // HEALTH
}

test "AppRouter: 未匹配路由不崩溃" {
    var ctx = RouteContext{ .req_id = 999, .modality = 0 };
    routeRequest(999, &ctx); // 未注册路由 → handleNotFound
}

test "AppRouter: 编译期类型安全验证" {
    // RouteContext 字段在编译期可见，无需 @ptrCast
    var ctx = RouteContext{ .req_id = 42, .modality = 1 };
    std.debug.assert(ctx.req_id == 42);
    routeRequest(1, &ctx);
}
