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
const p9 = @import("integration_p9.zig");
const p10 = @import("integration_p10.zig");
const p11 = @import("integration_p11.zig");
const p12 = @import("integration_p12.zig");
const p13 = @import("integration_p13.zig");
const p14 = @import("integration_p14.zig");
const p15 = @import("integration_p15.zig");
const p17 = @import("integration_p17.zig");
const p18 = @import("integration_p18.zig");
const p19 = @import("integration_p19.zig");
const p20 = @import("integration_p20.zig");
const p16 = @import("integration_p16.zig"); // 现在回归调试
const p21 = @import("integration_p21.zig");
const p22 = @import("integration_p22.zig");
//const p23 = @import("integration_p23.zig"); // 暂时禁用，等待修复
const p24 = @import("integration_p24.zig");
const p25 = @import("integration_p25.zig");
const p26 = @import("integration_p26.zig");
const p30 = @import("integration_p30.zig");
const tok = @import("token.zig");
const quant = @import("quantizer.zig");
const sb = @import("sub_brain.zig");
const orch = @import("orchestrator.zig");

comptime {
    _ = p3;
    _ = p4;
    _ = p5;
    _ = p6;
    _ = p7;
    _ = p8;
    _ = p9;
    _ = p10;
    _ = p11;
    _ = p12;
    _ = p13;
    _ = p14;
    _ = p15;
    _ = p16;
    _ = p17;
    _ = p18;
    _ = p19;
    _ = p20;
    _ = p21;
    _ = p22;
    //_ = p23; // 暂时禁用
    _ = p24;
    _ = p25;
    _ = p26;
    _ = p30;
    _ = tok;
    _ = quant;
    _ = sb;
    _ = orch;
}
