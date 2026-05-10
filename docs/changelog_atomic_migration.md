# Changelog: ZigClaw-AI 原子化 & 观测层迁移

> DRD-058 | 2026-05-10 | Hermes Agent 执行

## P0: 依赖治理

### P0-1: 整包导入消除（47 个文件）

**变更**：将 `const std = @import("std");` 替换为精确子导入。

**影响文件**：`src/integration_p{3,4,5,6,7,8,9,10,11,12,14,15,16,17,18,19,20,21,22,23,24,25,30,31,32,33,34,35,36,37,38,39,40,41,47,48,49,50,51,52,53,54,55,56,57,58}.zig`

| 导入模块 | 文件数 | 示例 |
|----------|--------|------|
| `std.testing` | 30 | integration_p3, p4, p5... |
| `std.mem` | 20 | integration_p5, p14, p22... |
| `std.debug` | 16 | integration_p18, p31, p33... |
| `std.fmt` | 6 | integration_p30, p39, p40... |
| `std.heap` | 5 | integration_p37, p39, p40... |
| `std.time` | 3 | integration_p39, p41, p51... |
| `std.net` | 1 | integration_p40 |
| `std.log` | 1 | integration_p34 |
| `std.os` | 1 | integration_p57 |
| `std.http` | 1 | integration_p51 |
| `std.process` | 1 | integration_p51 |
| `std.meta` | 1 | integration_p3 |

**构建影响**：无——精确子导入与整包导入语义等价。

### P0-2: CI 代码规范文档

**新增**：`docs/ci_code_review.md`

**包含规则**：
1. 禁止整包导入 `std`
2. `std.testing` 仅限 `_test.zig`
3. `atomic.Value` 必须使用 `.load()`/`.store()` 方法
4. `@deprecated` 必须附带迁移说明
5. 编译期对齐守卫

---

## P1: 核心源码修改

### P1-1: metrics.zig 原子化

**文件**：`src/metrics.zig`

**变更**：
- `buckets_initialized: bool` → `buckets_initialized = atomic.Value(bool).init(false)`
- 所有 4 处读取 → `.load(.acquire)`
- 所有 2 处写入 → `.store(true/.false, .release)`
- 移除冗余的 `const std = @import("std")`（已有 `const atomic = @import("std").atomic`）

**内存序**：
- 读：`.acquire` — 确保读到之前所有写入
- 写：`.release` — 确保写入对其他线程可见

### P1-2: ibus.zig 迁移到 LayerMetrics

**文件**：`src/ibus.zig`

**废弃 API**（v3.1 移除）：
| 旧 API | 替代 |
|--------|------|
| `ModelFeedback` | `feedback.LayerMetrics` |
| `LatencyAttentionEvents` | `feedback.EntryMetrics` / 对应子类型 |
| `write_metrics()` | `ibus.record(layer, metrics)` |
| `read_metrics()` | `ibus.readMetrics()` |

**新增 API**：
- `ibus.init()` — 初始化所有指标存储
- `ibus.record(layer, metrics)` — 按层更新指标（接受 `LayerMetrics` 联合）
- `ibus.readMetrics()` — 返回完整 `LayerMetrics` 快照

**新增废弃标注**：`@deprecated` + 迁移路径注释

---

## P2: 文档化

### P2-1: 变更影响分析

**编译兼容性**：
- ✅ 47 个测试文件：纯语法替换，无语义变更
- ✅ metrics.zig：API 不变，内部实现改为原子化
- ✅ ibus.zig：旧 API 保留（标注 deprecated），新 API 并存

**测试影响**：
- `ibus.zig` 原有 P46 单元测试继续通过（测试的是废弃 API）
- 建议后续添加 P47/P48 测试新 `record()`/`readMetrics()` API

### P2-2: 迁移指南

**调用方迁移步骤**：
```zig
// ❌ 旧方式（v3.0 废弃）
ibus.write_metrics(.{
    .ssd_heat_version_flip_rate = 0.5,
    ...
});
const fb = ibus.read_metrics();

// ✅ 新方式
ibus.record(.entry, .{
    .request_count = 1000,
    .error_count = 5,
    .p50_latency_us = 120,
    ...
});
const metrics = ibus.readMetrics();
```

**版本计划**：
- v3.0：新旧 API 并存，标注 deprecated
- v3.1：移除 ModelFeedback 系列
- v3.2：`formatBusStatus()` 全面使用 `readMetrics()` 输出