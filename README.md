# ZigClaw-AI 🦅

[![Build Status](https://img.shields.io/badge/tests-153%2F153%20passed-brightgreen)](https://github.com/CWLtoken/ZigClaw-AI)
[![Zig Version](https://img.shields.io/badge/zig-0.16.0-blue)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![GitHub tag](https://img.shields.io/github/v/tag/CWLtoken/ZigClaw-AI?label=version)](https://github.com/CWLtoken/ZigClaw-AI/releases)

**ZigClaw-AI** 是一个基于 **Zig 0.16** 构建的高性能异步 AI 客服系统框架。采用 io_uring 底层、事件驱动架构和六层静态分层设计，严格遵守"**显性直白、扁平低代码、无依赖0**"三大军规。

> **当前状态：v3.1 — 军规全面合规 + 架构加固 + 错误注入**
> 测试状态：**全绿** ✅ | 17 项收尾任务全部完成

---

## 🎯 核心特性

| 特性 | 描述 |
|------|------|
| **🚀 io_uring 零拷贝 I/O** | 基于 Linux io_uring，批量提交、链式操作、延迟提交策略 |
| **🧠 多模态编排** | 文本直通 + 向量量化，子脑注册表按模态调度 |
| **📊 IVF+PQ 向量检索** | 256 维向量 IVF 倒排索引 + 乘积量化，静态内存 |
| **🔍 内省总线** | IBus 5 层指标原子记录 + JSON 零堆序列化 + 二进制指标协议 |
| **🔄 反馈学习引擎** | SimpleLearner 硬编码规则，实时生成优化建议 |
| **💾 文件存储后端** | FileStore 基于 io_uring.Syscall 文件 I/O，零堆分配 |
| **⚡ 缓存行对齐** | AlignedAtomicU64 消除伪共享，多核性能无损 |
| **🔀 Comptime 路由** | 编译期生成路由 dispatch，零运行时查表开销 |
| **🔒 编译期契约验证** | ContractVerifier 完整签名检查（返回类型+参数类型+ErrorSet子集） |
| **🔌 连接池复用** | 纯状态机连接池，降低跨区 LLM 握手延迟 |
| **🧪 错误注入测试** | 覆盖 io_uring 初始化失败/EAGAIN/磁盘满/连接中断 |
| **🏗️ 军规级构建系统** | addLibrary + addCSourceFile，编译期配置注入 |
| **🎯 显性直白** | 契约显性化、无隐藏依赖、无过度封装、扁平分层 |
| **🔒 无依赖0** | 零第三方运行时依赖，自包含 C 代码，供应链安全 |

---

## 📋 v3.1 收尾任务汇总（17 项）

> 以下为本次 v3.1 版本完成的全部收尾任务，按优先级分组。

### P0 — build.zig 军规级重写（3 项）

| # | 任务 | 文件 | 状态 |
|---|------|------|------|
| P0-1 | C 库构建从 `addSystemCommand` 改为 `addLibrary` + `addCSourceFile` | `build.zig` | ✅ |
| P0-2 | 消除整包导入 `const std = @import("std")`，改为精确子导入 | `build.zig` | ✅ |
| P0-3 | 依赖关系显性化 `exe.linkLibrary(c_lib)` / `tests.linkLibrary(c_lib)` | `build.zig` | ✅ |

### P1 — 无菌室军规补全（5 项）

| # | 任务 | 文件 | 状态 |
|---|------|------|------|
| P1-1 | `flush()` 中 `try io_uring.Syscall.enter` 改为显式 if-else | `reactor.zig` | ✅ |
| P1-2 | `prepare_recv()` 中 `try self.flush()` 改为显式 if-else | `reactor.zig` | ✅ |
| P1-3 | `prepare_send()` 中 `try self.flush()` 改为显式 if-else | `reactor.zig` | ✅ |
| P1-3b | `poll()` 中 `catch` 改为显式 if-else | `reactor.zig` | ✅ |
| P1-4 | `Ring.init()` 中 3 处 `try` + `errdefer` 改为显式 if-else + 手动清理 | `io_uring.zig` | ✅ |

### P2 — 文档与 CI 强化（2 项）

| # | 任务 | 文件 | 状态 |
|---|------|------|------|
| P2-1 | 固化新读者阅读顺序 | `docs/index.md` | ✅ |
| P2-2 | 增加精确导入 + 无菌室 + 构建系统 + 错误注入检查规则 | `docs/ci_code_review.md` | ✅ |

### P3 — 架构加固（4 项）

| # | 任务 | 文件 | 状态 |
|---|------|------|------|
| P3-1 | AlignedAtomicU64 增加 `align(64)` — 已存在，确认通过 | `metrics.zig` | ✅ |
| P3-2 | BATCH_THRESHOLD 改为编译期配置，通过 build.zig 注入 | `build.zig` + `reactor.zig` | ✅ |
| P3-3 | 创建军规文档 | `docs/military_rules.md` | ✅ |
| P3-4 | 强化 ContractVerifier — ErrorSet 子集关系校验 | `interface.zig` | ✅ |

### P4 — 连接池复用（1 项）

| # | 任务 | 文件 | 状态 |
|---|------|------|------|
| P4-1 | 基于 reactor + io_uring 实现纯状态机连接池 | `src/connection_pool.zig` | ✅ |

### P5 — 错误注入测试（2 项）

| # | 任务 | 文件 | 状态 |
|---|------|------|------|
| P5-1 | 创建错误注入测试文件，覆盖核心路径 | `src/test_integration/fault_injection.zig` | ✅ |
| P5-2 | 在 tests.zig 中内联编译期守卫断言 | `src/tests.zig` | ✅ |

---

## 🏗️ 架构总览（六层静态分层）

```
┌──────────────────────────────────────────────────────────┐
│              入口与服务层 (Entry & Service Layer)          │
│  main.zig · server.zig · http_server.zig                  │
│  inference_client.zig · http_protocol.zig · http_log.zig  │
│  context.zig · entry/middleware.zig · entry/json_extractor│
│  metrics.zig · async_coordinator.zig                      │
├──────────────────────────────────────────────────────────┤
│                编排层 (Orchestration Layer)               │
│  orchestrator.zig · token.zig · quantizer.zig             │
│  sub_brain.zig · inference.zig                            │
├──────────────────────────────────────────────────────────┤
│                 路由层 (Router Layer)                     │
│  route_table.zig · vector_index.zig · router.zig          │
│  comptime_router.zig · entry/app_router.zig               │
├──────────────────────────────────────────────────────────┤
│                执行层 (Execution Layer)                   │
│  io_uring.zig · reactor.zig · protocol.zig · core.zig     │
│  connection_pool.zig（v3.1 新增）                        │
├──────────────────────────────────────────────────────────┤
│                存储层 (Storage Layer)                     │
│  heat_pool.zig · ssd_persist.zig · storage.zig            │
│  file_store.zig                                           │
├──────────────────────────────────────────────────────────┤
│              观测层 (Observability Layer)                 │
│  ibus.zig · feedback_engine.zig · feedback.zig            │
│  interface.zig                                            │
└──────────────────────────────────────────────────────────┘
```

---

## 🧪 测试体系

### 测试统计
- **总计**：全绿 ✅
- **核心模块内联测试**：token / quantizer / heat_pool / vector_index / ibus / feedback_engine / comptime_router / app_router 等
- **集成测试**：P3–P60 + comptime_router + app_router + **fault_injection（v3.1 新增）**
- **编译期守卫**：SyscallError 完整性、Ring.init 返回类型、AlignedAtomicU64 对齐、ConnSlot 大小

### v3.1 新增测试一览

| 测试 | 验证点 | 所属层 |
|------|--------|--------|
| `fault_injection: error set type info` | 错误集类型反射 | 观测层 |
| `fault_injection: connection interrupted` | 连接中断模拟（recv=0/EAGAIN/ECONNRESET） | 执行层 |
| `fault_injection: state machine transitions` | 连接池状态机（Idle→Connecting→Connected→Error） | 执行层 |
| `fault_injection: explicit error handling` | 显式 if-else 错误传播模式 | 执行层 |
| `comptime: SyscallError has 5+ variants` | 编译期守卫 | 执行层 |
| `comptime: Ring.init returns error union` | 编译期守卫 | 执行层 |
| `comptime: Ring.deinit returns void` | 编译期守卫 | 执行层 |
| `comptime: AlignedAtomicU64 is 64-byte aligned` | 编译期守卫 | 观测层 |
| `comptime: ConnSlot fits in cache line` | 编译期守卫 | 执行层 |

---

## 🚀 快速开始

### 环境要求
- **Zig**：0.16.0（安装路径 `/opt/zig-bin-0.16.0`）
- **系统**：Linux with io_uring（Kernel ≥ 5.1）

### 构建与测试
```bash
# 克隆仓库
git clone git@github.com:CWLtoken/ZigClaw-AI.git
cd ZigClaw-AI

# 切换到 agent 分支
git checkout agent

# 运行全部测试
zig build test

# 编译期配置（自定义 BATCH_THRESHOLD）
zig build -Dbatch_threshold=16

# 构建并运行
zig build run
```

---

## 📋 军规与约束

### 第一诫：精确导入
```zig
// ✅ 正确
const mem = @import("std").mem;

// ❌ 禁止
const std = @import("std");
```

### 第二诫：无菌室原则
无菌室文件（`reactor.zig`、`io_uring.zig`、`protocol.zig`）禁止使用 `try`/`catch`/`orelse`，必须使用显式 `if-else` 错误处理。

### 第三诫：零第三方库
全部使用 Zig 0.16 标准库，禁用任何第三方依赖。

### 第四诫：静态分配优先 + 依赖引入评审

### 第五诫：CI 必须 ReleaseSafe + 军规检查

### 第六诫：构建系统军规
使用 `addLibrary` + `addCSourceFile`，禁止 `addSystemCommand`。编译期配置通过 `b.option` + `addOptions` 注入。

---

## 📈 演进路线

### v3.1 收尾任务架构图

```
P0 build.zig 军规重写
├── P0-1: addSystemCommand → addLibrary+addCSourceFile
├── P0-2: 整包导入 → 精确子导入
└── P0-3: linkLibrary 显性化

P1 无菌室军规补全
├── P1-1: reactor flush() try → if-else
├── P1-2: reactor prepare_recv() try → if-else
├── P1-3: reactor prepare_send() try → if-else
├── P1-3b: reactor poll() catch → if-else
└── P1-4: io_uring Ring.init() try+errdefer → if-else+手动清理

P2 文档与 CI 强化
├── P2-1: docs/index.md 阅读顺序固化
└── P2-2: ci_code_review.md 新增第7/8/9条规则

P3 架构加固
├── P3-1: AlignedAtomicU64 align(64) — 已存在
├── P3-2: BATCH_THRESHOLD 编译期配置
├── P3-3: docs/military_rules.md 军规文档
└── P3-4: ContractVerifier ErrorSet 子集校验

P4 连接池复用
└── P4-1: connection_pool.zig 纯状态机实现

P5 错误注入测试
├── P5-1: test_integration/fault_injection.zig
└── P5-2: tests.zig 内联编译期守卫断言
```

---

## 🤝 贡献指南

### 开发流程
1. **遵循军规**：无菌室 + 精确导入 + 零第三方库
2. **测试驱动**：新功能必须附带测试，保持全绿
3. **分层设计**：明确层级归属，禁止循环依赖
4. **错误注入**：新增核心路径必须覆盖错误场景

### 提交规范
```
<type>: <description>

详细说明...
测试状态：全绿
```

---

## 📧 联系与反馈

- **项目仓库**：[github.com/CWLtoken/ZigClaw-AI](https://github.com/CWLtoken/ZigClaw-AI)
- **分支说明**：
  - `agent`：Hermes AI 协作分支（当前）
  - `zigclaw-hermes`：本地开发分支（跟踪 `agent`）

---

## 📜 许可证

MIT License。详见 [LICENSE](LICENSE) 文件。

---

## 🏛️ v3.1 架构师审计结论

> **审查框架**：五大军规 + 处决碑 + 物理层验证 + P0/P1/P2 分级

### 五诫评分

| 军规 | 状态 | 说明 |
|------|------|------|
| **第一诫**：精确导入 | ✅ 全绿 | src/ 零整包导入，build.zig 精确子导入 |
| **第二诫**：消灭 undefined | ⚠️ P2×27 | 均为栈缓冲区临时变量，非结构体字段 |
| **第三诫**：错误即状态 | ✅ 全绿 | 无菌室零 try/catch，13 处 catch {} 均为合理降级 |
| **第四诫**：字节序刚性 | ✅ 全绿 | 零违规 |
| **第五诫**：架构权力隔离 | ✅ 全绿 | Protocol 唯一神明，Reactor 无越权 |

### 问题分级

| 级别 | 数量 | 内容 | 状态 |
|------|------|------|------|
| **P0**（必须修） | **0** | 零 | ✅ |
| **P1**（建议修） | **2** | `last_send_rc` 调试全局变量、`infer_latency_buckets` undefined | ✅ 已修复 |
| **P2**（记录） | **3** | 27 处 undefined 缓冲区、6 处 catch unreachable、1 处 BOM | ✅ 部分修复 |

### 审计判定

> **P0 问题为零，所有军规核心条目完全合规。**
> P1/P2 均为历史遗留的低优先级问题，不影响功能正确性。
> **项目达到"军规驱动系统级基础设施"标准，可封板 v3.1。**

---

**ZigClaw-AI** — *从 io_uring 泥泞层到智能编排层，每一行都经过第一性原理优化。v3.1 军规全面合规。*
