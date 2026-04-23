// src/tests.zig
// ZigClaw V2.4 | 统一测试网关 | 显性路由，拒绝合并
// 编译器从该文件切入，通过 @import 物理拉取各阶段测试
// 各阶段文件保持独立，历史边界不被污染
//
// 军规：@import 的模块必须被引用，否则 Zig 死代码消除会丢弃 test 块
// comptime 引用是 Zig 标准模式，确保编译期可见（非 hack）

const p3 = @import("integration_p3.zig");
const p4 = @import("integration_p4.zig");
const p5 = @import("integration_p5.zig");
const p6 = @import("integration_p6.zig");
const p7 = @import("integration_p7.zig");
const p8 = @import("integration_p8.zig");

comptime {
    _ = p3;
    _ = p4;
    _ = p5;
    _ = p6;
    _ = p7;
    _ = p8;
}
