     1|// src/tests.zig
     2|// ZigClaw V2.4 | 统一测试网关 | 显性路由，拒绝合并
     3|// 编译器从该文件切入，通过 @import 物理拉取各阶段测试
     4|// 各阶段文件保持独立，历史边界不被污染
     5|//
     6|// 军规：@import 的模块必须被引用，否则 Zig 死代码消除会丢弃 test 块
     7|// comptime 引用是 Zig 标准模式，确保编译期可见（非 hack）
     8|
     9|const p3 = @import("integration_p3.zig");
    10|const p4 = @import("integration_p4.zig");
    11|const p5 = @import("integration_p5.zig");
    12|const p6 = @import("integration_p6.zig");
    13|const p7 = @import("integration_p7.zig");
    14|const p8 = @import("integration_p8.zig");
    15|const p9 = @import("integration_p9.zig");
    16|const p10 = @import("integration_p10.zig");
    17|const p11 = @import("integration_p11.zig");
    18|const p12 = @import("integration_p12.zig");
    19|const p13 = @import("integration_p13.zig");
    20|const p14 = @import("integration_p14.zig");
    21|const p15 = @import("integration_p15.zig");
    23|const p18 = @import("integration_p18.zig");
    24|const p19 = @import("integration_p19.zig");
    25|const p20 = @import("integration_p20.zig");
    26|const p16 = @import("integration_p16.zig"); // 现在回归调试
    27|const p21 = @import("integration_p21.zig");
    28|const p22 = @import("integration_p22.zig");
    29|const p23 = @import("integration_p23.zig"); // P23: 1024轮压力测试
    30|const p24 = @import("integration_p24.zig");
    31|const p25 = @import("integration_p25.zig");
    32|const p26 = @import("integration_p26.zig");
    33|const p30 = @import("integration_p30.zig");
    34|const p31 = @import("integration_p31.zig"); // P31: infer_from_tokens 全链路验证
    35|const p32 = @import("integration_p32.zig"); // P32: 图像子脑（LCG 256维）全链路
    36|const tok = @import("token.zig");
    37|const quant = @import("quantizer.zig");
    38|const sb = @import("sub_brain.zig");
    39|const orch = @import("orchestrator.zig");
    40|
    41|comptime {
    42|    _ = p3;
    43|    _ = p4;
    44|    _ = p5;
    45|    _ = p6;
    46|    _ = p7;
    47|    _ = p8;
    48|    _ = p9;
    49|    _ = p10;
    50|    _ = p11;
    51|    _ = p12;
    52|    _ = p13;
    53|    _ = p14;
    54|    _ = p15;
    55|    _ = p16;
    57|    _ = p18;
    58|    _ = p19;
    59|    _ = p20;
    60|    _ = p21;
    61|    _ = p22;
    62|    _ = p23; // P23: 1024轮压力测试
    63|    _ = p24;
    64|    _ = p25;
    65|    _ = p26;
    66|    _ = p30;
    67|    _ = p31; // P31: infer_from_tokens 全链路验证
    68|    _ = p32; // P32: 图像子脑（LCG 256维）全链路
    69|    _ = tok;
    70|    _ = quant;
    71|    _ = sb;
    72|    _ = orch;
    73|}
    74|