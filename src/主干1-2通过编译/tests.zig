// src/tests.zig
// ZigClaw V2.4 | 统一测试网关 | 显性路由，拒绝合并
// 编译器从该文件切入，通过 @import 物理拉取各阶段测试
// 各阶段文件保持独立，历史边界不被污染

_ = @import("integration_p3.zig");
_ = @import("integration_p4.zig");
_ = @import("integration_p5.zig");
