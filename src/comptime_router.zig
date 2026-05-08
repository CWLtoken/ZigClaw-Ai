// src/comptime_router.zig
// P2-3: Comptime 路由表代码生成 — 通用框架
//
// 设计原则：
//   - 零运行时路由开销：编译期展开为完美 switch
//   - 显式直白：RouteContext 替代 *anyopaque，编译期类型安全
//   - 扁平低代码：无运行时哈希表、无动态注册、无虚表
//   - 无依赖0：只依赖 std
//
// 用法：
//   1. 定义 RouteContext（包含路由所需的所有上下文字段）
//   2. 定义 Route 数组（op_code → handler 映射）
//   3. 用 ComptimeRouter(routes) 生成 dispatch 函数
//   4. 编译期自动检测重复 op_code

const std = @import("std");

// ============================================================================
// 路由上下文（显式直白，替代 *anyopaque）
// 包含路由处理函数所需的所有字段，编译期类型安全
// ============================================================================

pub const RouteContext = struct {
    req_id: u64,
    modality: u8,
    // 可扩展：tenant_id, path, method 等
};

// ============================================================================
// 路由配置
// ============================================================================

pub const Route = struct {
    op_code: u16,
    handler: *const fn (ctx: *RouteContext) void,
};

// ============================================================================
// Comptime 路由生成器（通用框架）
// ============================================================================

pub fn ComptimeRouter(comptime routes: []const Route) type {
    return struct {
        /// 编译期生成的 dispatch 函数
        /// inline for 展开为平铺 if-else，优化器生成跳转表
        pub fn dispatch(op_code: u16, ctx: *RouteContext) void {
            inline for (routes) |route| {
                if (route.op_code == op_code) {
                    route.handler(ctx);
                    return;
                }
            }
            handleNotFound(ctx);
        }

        // 编译期验证：路由表无重复 op_code
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

/// 默认未匹配路由处理（pub，供 ComptimeRouter 调用）
pub fn handleNotFound(ctx: *RouteContext) void {
    _ = ctx;
    std.log.warn("[ComptimeRouter] Route not found for op_code", .{});
}

// ============================================================================
// 单元测试
// ============================================================================

test "ComptimeRouter: 框架编译期验证" {
    // 测试编译期重复 op_code 检测
    // 以下代码应该编译失败（重复 op_code=1）：
    // const bad_router = ComptimeRouter(&.{
    //     .{ .op_code = 1, .handler = handleNotFound },
    //     .{ .op_code = 1, .handler = handleNotFound },
    // });
    // 取消注释上一行来验证编译期错误
}
