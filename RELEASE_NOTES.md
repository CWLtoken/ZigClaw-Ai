# ZigClaw v2.4 Release Notes

**发布日期**：2026-05-06  
**版本标签**：`v5.8-final`  
**提交哈希**：`0d1d0a5`  
**测试基线**：**86/86 全绿** ✅

---

## 🎯 版本概述

**ZigClaw v2.4 – 泥泞双轨制 io_uring 客服 AI 引擎**

这是 ZigClaw 项目的正式封板版本，完成了从 Phase 0 到 Phase 17 + P42-P46 的全部开发工作。严格遵循五层架构（编排/路由/执行/存储/观测）+ 独立入口与服务层设计，实现零第三方依赖、静态内存分配、无堆分配的高性能 AI 客服系统框架。

---

## 🧪 测试基底

**86 个集成测试**，覆盖完整能力栈：

| 测试范围 | 数量 | 覆盖内容 |
|---------|------|----------|
| io_uring 底层 | 10+ | setup/mmap/enter/register/poll |
| 协议状态机 | 5+ | Idle→HeaderRecv→BodyRecv→BodyDone→SendDone + WaitRequest keep-alive |
| 多连接事件循环 | 3+ | 并发连接、事件处理 |
| 编排层向量化 | 4+ | Token 定义、码本量化、子脑注册、文本直通/图像量化 |
| 推理引擎框架 | 5+ | 模拟推理、AsyncHandlerFn、回调机制 |
| HTTP 服务化 | 8+ | 路由分发、健康检查、并发验证、指标收集 |
| 可观测性与故障恢复 | 5+ | IBus 指标、SSD 持久化、错误恢复 |
| 新增模块（P42-P46） | 10 | HeatPool、SSDPersist、VectorIndex、RouteTable、IBus |

**测试状态**：✅ **86/86 全绿**（无回归、无泄漏、无挂起）

---

## 🏗️ 架构

### 五层核心引擎

```
入口与服务层（Entry & Service Layer）
  └─ 五层核心引擎
      ├─ 编排层（Orchestration）：Token + Quantizer + SubBrain + Orchestrator
      ├─ 路由层（Router）：Router + VectorIndex + RouteTable
      ├─ 执行层（Execution）：Protocol + Reactor + io_uring
      ├─ 存储层（Storage）：Storage + Epoch + HeatPool + SSDPersist
      └─ 观测层（Observability）：IBus
```

### 层间依赖规则（军规）

| 层 | 允许访问 | 禁止访问 |
|----|---------|---------|
| 入口与服务层 | 五层公开接口 | 五层内部实现 |
| 编排层 | 路由层、执行层接口 | 存储层、观测层内部结构 |
| 路由层 | 执行层接口 | 存储层、观测层 |
| 执行层 | 无（底层） | 上层所有层 |
| 存储层 | 无（独立） | 执行层、协议层 |
| 观测层 | 无（独立） | 执行层、协议层 |

✅ **层间连接检查通过**：`protocol.zig` 不直接访问 `ring` 内部字段，存储/路由/观测层不导入 `reactor.zig`/`protocol.zig`。

---

## 🔧 核心技术

### 零第三方依赖
- ✅ 全部使用 **Zig 0.16 标准库**实现
- ✅ 禁止使用任何第三方库
- ✅ 静态内存分配，无堆分配

### io_uring 系统调用降维
- ✅ `io_uring.Syscall.setup()` - 初始化 ring
- ✅ `io_uring.Syscall.mmap()` - 内存映射
- ✅ `io_uring.Syscall.enter()` - 提交/等待事件
- ✅ `io_uring.Syscall.register()` - 注册文件/缓冲区
- ✅ `io_uring.Syscall.poll()` - 事件轮询

### 五状态机 Protocol
- ✅ **Idle** → **HeaderRecv** → **BodyRecv** → **BodyDone** → **SendDone**
- ✅ **WaitRequest** 支持 keep-alive 连接复用
- ✅ 状态机内无 `try`/`catch`/`orelse`/`?`（军规）

### 多模态编排
- ✅ **Token 系统**：Text/VectorQuantized 双模，512 字节编译期守卫
- ✅ **量化器**：256 码本，余弦相似度 ≥ 0.92（1000 组随机向量验证）
- ✅ **子脑接口**：文本直通（零量化开销）、图像/音频（预留）
- ✅ **编排器**：子脑注册表（最大 8 个），按模态调度

### 异步推理协调器
- ✅ **AsyncHandlerFn** 异步处理函数指针
- ✅ **回调机制**：推理完成通知
- ✅ **忙碌拒绝**：无待处理时返回 false

### HTTP 推理服务
- ✅ **路由分发**：`/health`、`/health?verbose=true`、`/infer?input=xxx&modality=text|image`
- ✅ **健康检查**：基础指标 + 详细指标
- ✅ **并发验证**：多 HTTP 请求顺序处理
- ✅ **指标收集**：ServerMetrics（总请求、错误计数、活跃连接）

### Keep-Alive & 故障恢复
- ✅ **连接复用**：WaitRequest 状态支持 keep-alive
- ✅ **超时处理**：请求超时自动关闭连接
- ✅ **错误恢复**：客户端断开不泄漏 fd
- ✅ **SSD 持久化框架**：HeatPool 双版本页原子切换（简化版）

---

## 📦 新增模块（P42-P46）

| 模块 | 层级 | 功能 | 测试 |
|------|------|------|------|
| `heat_pool.zig` | 存储层 | 热度池（动态分段指数衰减） | 3 tests |
| `ssd_persist.zig` | 存储层 | SSD 持久化（双版本页原子切换） | 1 test |
| `vector_index.zig` | 路由层 | 向量索引（256-dim 余弦相似度搜索） | 2 tests |
| `route_table.zig` | 路由层 | 路由表（op_code → HandlerFn，256 槽） | 2 tests |
| `ibus.zig` | 观测层 | I-Bus（ModelFeedback 指标收集） | 2 tests |

**数学精度修正（v5.8-final）**：
- ✅ `heat_pool.zig`：`@log()` 和衰减公式显式转换到 f64
- ✅ `vector_index.zig`：`@sqrt()` 显式转换到 f64

---

## 🚪 入口与服务层

| 模块 | 职责 | 测试 |
|------|------|------|
| `main.zig` | 程序入口，初始化各层，优雅关闭 | 集成测试 |
| `server.zig` | TCP 脚手架（不导入 Protocol/Reactor，不持有 Storage 指针） | P5-P7 |
| `http_server.zig` | HTTP 路由分发、健康检查、推理接口 | P40-P41 |
| `inference_client.zig` | OpenRouter/Ollama 推理接入 | P11-P16 |

**依赖规则**：
- ✅ 允许导入五层核心引擎的**公开接口**
- ❌ 禁止导入五层核心引擎的**内部实现**

---

## ⚠️ 已知限制

1. **TLS 依赖 Zig 0.17**：`std.crypto.tls` 稳定后启用 HTTPS 推理接入
2. **Ollama 存根待启用**：当前为模拟实现，真实推理引擎接入留给 v3.0
3. **uptime 指标未实现**：ServerMetrics 中预留字段，后续版本补充
4. **向量检索引擎优化**：当前暴力搜索（64 向量），大规模优化留给 v3.0
5. **IBus 内省总线增强**：当前单线程环境，多线程原子性留给 v3.0

---

## 📈 演进路线

### 已完成（v2.4 封板）
- ✅ Phase 0-2：基础设施 + Ring 真实化
- ✅ Phase 3-12：io_uring 泥泞层（批量/链式/错误恢复）
- ✅ Phase 13-15：Reactor 盲盒层 + 双向引擎
- ✅ Phase 16-17：协议层 + 推理框架 + 编排层向量化
- ✅ P42-P46：五层架构对齐（存储层 + 路由层 + 观测层）
- ✅ 入口与服务层正式定义
- ✅ 数学精度修正（f32→f64 显式转换）
- ✅ 文档完整同步（architecture.md + README.md）

### 后续演进（v3.0+）
| 任务 | 所属层 | 阻塞因素 |
|------|--------|----------|
| TLS 1.3 安全接入 | 执行层 | Zig 0.17 `std.crypto.tls` 稳定 |
| 真实推理引擎接入 | 入口层 | Ollama/OpenRouter API 完善 |
| 向量检索引擎优化 | 路由层 | 大规模向量搜索算法 |
| IBus 内省总线增强 | 观测层 | 多线程原子操作支持 |
| uptime 指标实现 | 入口层 | 无阻塞 |

---

## 🏁 项目归档

**ZigClaw v2.4 正式封板** 🎉

从 Phase 0 的黄金基线到 Phase 17 的编排层向量化，再到 P42-P46 的五层架构对齐，这条泥泞之路走了整整十七个阶段。

每一个 commit、每一个 Tag、每一块被推翻重写的代码、每一个被钉进处决碑的踩坑记录，都是这条路上不可磨灭的路标。

**保护好这份代码库，保护好每一个架构决策。它们比黄金更珍贵。**

---

## 📊 版本统计

| 项目 | 数值 |
|------|------|
| **测试数量** | 86（原 76 + 新增 10） |
| **核心模块** | 13 个（五层引擎） |
| **入口与服务层模块** | 4 个 |
| **代码行数** | ~5000 行（不含测试） |
| **测试覆盖率** | 五层架构全链路 |
| **第三方依赖** | 0 |
| **堆分配** | 0（全静态分配） |
| **Git Tags** | v5.6-docs-five-layer, v5.7-final-cleanup, v5.8-final |

---

**ZigClaw v2.4 – 泥泞之路，无可挑剔。封板。** 🎉
