// src/comptime_router.zig
// P2-3: Comptime 路由表代码生成
// 把路由配置从"运行时查表"改为"编译期生成 switch 跳转"
//
// 设计原则：
//   - 零运行时路由开销：编译期展开为完美 switch
//   - 与现有 route_table.zig 并存，验证后替换
//   - 显性直白：路由配置即代码，编译期可验证

const std = @import("std");

// ============================================================================
// 路由配置类型
// ============================================================================

pub const Route = struct {
    op_code: u16,
    handler: *const fn (ctx: *anyopaque) callconv(.c) void,
};

// ============================================================================
// Comptime 路由生成器
// ============================================================================

pub fn ComptimeRouter(comptime routes: anytype) type {
    return struct {
        pub fn dispatch(op_code: u16, ctx: *anyopaque) void {
            inline for (routes) |route| {
                if (route.op_code == op_code) {
                    route.handler(ctx);
                    return;
                }
            }
            // 未匹配路由：默认处理
            handleNotFound(ctx);
        }

        comptime {
            var i: usize = 0;
            while (i < routes.len) : (i += 1) {
                var j: usize = i + 1;
                while (j < routes.len) : (j += 1) {
                    if (routes[i].op_code == routes[j].op_code) {
                        @compileError("ComptimeRouter: duplicate op_code");
                    }
                }
            }
        }
    };
}

// ============================================================================
// 默认处理函数
// ============================================================================

fn handleNotFound(ctx: *anyopaque) void {
    _ = ctx;
    std.log.warn("[ComptimeRouter] Route not found", .{});
}

// ============================================================================
// 示例路由处理函数（实际项目中替换为真实处理函数）
// ============================================================================

fn handleText(ctx: *anyopaque) void {
    _ = ctx;
    std.log.info("[ComptimeRouter] TEXT handler", .{});
}

fn handleImage(ctx: *anyopaque) void {
    _ = ctx;
    std.log.info("[ComptimeRouter] IMAGE handler", .{});
}

fn handleHealth(ctx: *anyopaque) void {
    _ = ctx;
    std.log.info("[ComptimeRouter] HEALTH handler", .{});
}

// ============================================================================
// 编译期实例化路由表
// ============================================================================

const app_router = ComptimeRouter(.{
    .{ .op_code = 1, .handler = handleText },
    .{ .op_code = 2, .handler = handleImage },
    .{ .op_code = 3, .handler = handleHealth },
});

// ============================================================================
// 对外暴露的调用入口
// ============================================================================

pub fn routeRequest(op_code: u16, ctx: *anyopaque) void {
    app_router.dispatch(op_code, ctx);
}

// ============================================================================
// 单元测试
// ============================================================================

test "ComptimeRouter: dispatch 不崩溃" {
    // 测试每个已注册的路由
    routeRequest(1, undefined); // TEXT
    routeRequest(2, undefined); // IMAGE
    routeRequest(3, undefined); // HEALTH
}

test "ComptimeRouter: 未匹配路由不崩溃" {
    // 测试未注册的路由（触发 handleNotFound）
    routeRequest(999, undefined);
}
