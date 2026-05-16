// src/constants.zig
// 全局共享常量 — 存储层 + 流窗口统一槽位数
//
// 设计原则（显性直白）：
//   所有模块引用此处的常量，禁止各自硬编码。
//   槽位数变化只改此处，全局同步。

/// 热度池 / 流窗口槽位数
/// 与 StreamWindow.capacity 保持一致
pub const SLOT_COUNT: usize = 64;
