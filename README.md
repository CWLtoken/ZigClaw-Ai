# ZigClaw-AI 🦅

[![Build Status](https://img.shields.io/badge/tests-153%2F153%20passed-brightgreen)](https://github.com/CWLtoken/ZigClaw-AI)
[![Zig Version](https://img.shields.io/badge/zig-0.16.0-blue)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![GitHub tag](https://img.shields.io/github/v/tag/CWLtoken/ZigClaw-AI?label=version)](https://github.com/CWLtoken/ZigClaw-AI/releases)

**ZigClaw-AI** 是一个基于 **Zig 0.16** 的高性能异步 AI 客服系统框架。底层采用 `io_uring`，六层静态分层，严格遵守 **"显性直白、扁平低代码、无依赖0"** 三大军规。

> 当前版本：**v3.4.1 — 军规驱动 + 架构师全局修复 + CI 编译修复 + P1 去 try**
> 测试状态：**153/153 通过** ✅

---

## 🛡️ 军规与核心特性

### 三大军规

| 军规 | 约束 | 典型做法 |
|------|------|----------|
| **显性直白** | 禁止隐式控制流与隐式依赖 | 无菌室文件禁止 `try/catch/orelse`；全部显式 `if-else`；契约与错误集在编译期校验 |
| **扁平低代码** | 扁平分层 + 零运行时查表 | 六层静态分层；Comptime 路由编译期生成 dispatch；零虚函数/零反射 |
| **无依赖0 (Zero Deps)** | 零第三方运行时依赖 | 只用 Zig 0.16 标准库 + 自包含 C 代码；C 库通过 `addLibrary + addCSourceFile` 构建 |

### 核心特性一览

| 特性 | 描述 |
|------|------|
| **🚀 io_uring 零拷贝 I/O** | 基于 Linux `io_uring`，批量提交、链式操作、延迟提交策略 |
| **🧠 多模态编排** | 文本直通 + 向量量化，子脑注册表按模态调度；当前支持 LongCat 长上下文拼接 |
| **📊 IVF+PQ 向量检索** | 256 维向量 IVF 倒排索引 + 乘积量化，**静态内存零堆分配** |
| **🔍 内省总线** | IBus 5 层指标原子记录 + JSON 零堆序列化 + 二进制指标协议 |
| **🔄 反馈学习引擎** | SimpleLearner 硬编码规则，实时生成优化建议；观测数据反哺编排，形成学习飞轮 |
| **💾 文件存储后端** | `FileStore` 基于 `io_uring.Syscall` 文件 I/O，零堆分配 |
| **⚡ 缓存行对齐** | `AlignedAtomicU64` 消除伪共享，多核性能无损 |
| **🔀 Comptime 路由** | 编译期生成路由 dispatch，零运行时查表开销 |
| **🔒 编译期契约验证** | `ContractVerifier` 完整签名检查（返回类型 + 参数类型 + ErrorSet 子集） |
| **🔌 连接池复用** | 纯状态机连接池，降低跨区 LLM 握手延迟 |
| **🧪 错误注入测试** | 覆盖 `io_uring` 初始化失败 / EAGAIN / 磁盘满 / 连接中断 |
| **🏗️ 军规级构建系统** | `addLibrary` + `addCSourceFile`，编译期配置注入（如 `batch_threshold`） |

---

## 🏛️ 架构总览（六层静态分层 + 契约层）

系统严格划分为六层，依赖方向单向向下，**禁止跨层直调**。层间交互通过 `interface.zig` 和 `feedback.zig` 的 `comptime` 契约强制校验。

```
┌─────────────────────────────────────────────────────────────────────┐
│  L1: 入口与服务层 (Entry & Service Layer)                           │
│  ├── main.zig              → 程序入口，初始化各层，启动 HTTP 服务器   │
│  ├── server.zig            → TCP 脚手架（socket/bind/listen）        │
│  ├── http_server.zig       → HTTP 服务器（Reactor 异步事件循环）     │
│  ├── http_protocol.zig     → HTTP 协议处理器（状态机解析）           │
│  ├── http_log.zig          → 结构化 JSON 请求日志（零堆）            │
│  ├── async_coordinator.zig → 异步推理协调器（回调模式）              │
│  ├── context.zig           → 请求上下文（原子 ID/租户/时间戳）       │
│  ├── metrics.zig           → Prometheus 指标（缓存行对齐原子变量）   │
│  ├── connection_pool.zig   → 连接池复用（纯状态机）                  │
│  ├── core.zig              → 核心数据定义（TokenStreamHeader 13B）  │
│  ├── entry/                                                         │
│  │   ├── middleware.zig    → Bearer Token 鉴权中间件                │
│  │   ├── json_extractor.zig→ 零拷贝 JSON 字段提取器                  │
│  │   └── app_router.zig    → 业务路由配置（文本/图像/音频 handler）  │
│  └── fault_injection.zig   → 错误注入测试模块（编译期可配置）        │
├─────────────────────────────────────────────────────────────────────┤
│  L2: 编排层 (Orchestration Layer)                                    │
│  ├── orchestrator.zig      → 子脑注册表（≤8个）/ 模态分发 / 量化调度 │
│  ├── sub_brain.zig         → 子脑接口（Text/Image/Audio/Unknown）    │
│  ├── quantizer.zig         → LCG 码本量化（256中心，余弦相似度≥0.92）│
│  ├── token.zig             → Token/TokenSequence（≤512B 编译期守卫） │
│  ├── inference.zig         → 推理引擎（Ollama 桥接，当前为模拟实现）  │
│  └── inference_client.zig  → Ollama 客户端存根（WIP，等待 Zig 0.17） │
├─────────────────────────────────────────────────────────────────────┤
│  L3: 路由层 (Router Layer)                                           │
│  ├── router.zig            → 请求路由（op_code → HandlerFn 分发）    │
│  ├── route_table.zig       → 多策略路由表（精确/前缀/Fallback）      │
│  ├── comptime_router.zig   → 编译期路由生成（零运行时开销）          │
│  └── vector_index.zig      → IVF+PQ 向量索引（256维，静态零堆）      │
├─────────────────────────────────────────────────────────────────────┤
│  L4: 执行层 (Execution Layer) [无菌室]                               │
│  ├── io_uring.zig          → io_uring 封装（Ring/SQE/CQE/Syscall）  │
│  ├── reactor.zig           → Reactor 盲盒层（BATCH=8 延迟提交）      │
│  └── protocol.zig          → 5 状态机（Idle→HeaderRecv→BodyRecv     │
│                                →BodyDone→SendDone→WaitRequest）     │
├─────────────────────────────────────────────────────────────────────┤
│  L5: 存储层 (Storage Layer)                                          │
│  ├── storage.zig           → StreamWindow（64槽）+ BodyBufferPool    │
│  ├── heat_pool.zig         → 热度池（64槽，动态分段指数衰减）        │
│  ├── ssd_persist.zig       → SSD 持久化（双版本页原子切换）          │
│  └── file_store.zig        → 文件存储后端（io_uring 异步文件 I/O）   │
├─────────────────────────────────────────────────────────────────────┤
│  L6: 观测层 (Observability Layer)                                    │
│  ├── ibus.zig              → I-Bus 内省总线（5层原子指标+JSON序列化）│
│  ├── feedback.zig          → 层指标契约（LayerMetrics union）        │
│  └── feedback_engine.zig   → SimpleLearner 规则引擎（5条硬编码规则） │
├─────────────────────────────────────────────────────────────────────┤
│  契约层 (Contract Layer) — 纯类型锚点，零运行时开销                   │
│  ├── interface.zig         → Executor/Storage/Orchestrator VTable    │
│  │                          ContractVerifier 编译期签名校验           │
│  └── feedback.zig          → Layer/Action/Suggestion 类型定义        │
└─────────────────────────────────────────────────────────────────────┘
```

### L1 — 入口与服务层

**职责**：对外暴露 HTTP/TCP 接口，请求准入控制，多租户上下文隔离。

| 组件 | 功能详解 |
|------|----------|
| **main.zig** | 程序入口。初始化 ServerMetrics → HttpServer.init() → 启动 Reactor 事件循环。全局服务器指针用于 SIGINT 优雅关闭。默认端口 8080。 |
| **server.zig** | TCP 网络脚手架。仅依赖 io_uring.Syscall，执行 socket→bind→listen。不导入 Protocol/Reactor/Storage（第四诫隔离）。 |
| **http_server.zig** | HTTP 服务器核心。基于 Reactor 异步事件循环，支持 Accept→Recv→Send→Close 全链路。Conn 结构体数组（256槽）管理连接状态，每个 Conn 持有独立的 recv_iov/send_iov/req。路由：/health（含 verbose 模式）、/metrics（Prometheus 格式）、/v1/infer（占位）。 |
| **http_protocol.zig** | HTTP 协议处理器。使用 Reactor 进行 HTTP I/O，实现 RequestLine→Headers→Body 状态机解析。支持 GET/POST，最大 64 个头，零堆分配。 |
| **http_log.zig** | 结构化 JSON 请求日志。栈缓冲区 512B，手工拼接 JSON，无堆分配。输出到 stdout。 |
| **async_coordinator.zig** | 异步推理协调器。桥接 HTTP 请求和异步推理结果，回调模式。不导入 reactor/protocol/storage（纯逻辑组件）。 |
| **context.zig** | 请求上下文。全局原子 ID 生成器（@atomicRmw），包含 tenant_id、timestamp_ms、method、path、auth_token_hash。 |
| **metrics.zig** | Prometheus 指标收集。AlignedAtomicU64（64字节缓存行对齐，消除伪共享），支持 load/store/rmw 原子操作。编译期 @alignOf/@sizeOf 守卫。 |
| **connection_pool.zig** | 连接池复用。纯状态机：Idle→Connecting→Connected→Keepalive→Error→Idle。基于 reactor+io_uring，降低跨区 LLM 握手延迟。 |
| **core.zig** | 核心数据定义。TokenStreamHeader（13字节：stream_id u64 LE + total_len u32 LE + op_code u8）。 |
| **middleware.zig** | Bearer Token 鉴权。零堆分配，直接比较常量字符串 "secret-token-123"。 |
| **json_extractor.zig** | 零拷贝 JSON 提取器。在 JSON 缓冲区中定位 "input" 字段位置（返回 start/end/quoted），不复制字符串。 |
| **app_router.zig** | 业务路由配置。依赖 comptime_router 通用框架，定义 handleText/handleImage/handleAudio 等 handler。 |
| **fault_injection.zig** | 错误注入测试。编译期可配置（-Dfault_injection=true），模拟 io_uring 初始化失败、EAGAIN、磁盘满、连接中断。 |

### L2 — 编排层

**职责**：多模态输入统一化，子脑分发调度，Token 量化编码，推理执行。

| 组件 | 功能详解 |
|------|----------|
| **orchestrator.zig** | 编排器核心。子脑注册表（MAX_BRAINS=8），按模态分发：Text→直通，Image→LCG 64维量化。orchestrate() → TokenSequence → infer_from_tokens()。 |
| **sub_brain.zig** | 子脑接口。定义 SubBrain struct（name/extract_fn/input_modality/dim）。内置 textExtract（直通返回 TextPassthrough）和 imageExtract（调用 C FFI extract_image_features）。模态：Text/Image/Audio/Unknown。 |
| **quantizer.zig** | LCG 码本量化器。256个中心，码本初始化：单位向量+角度偏移（前2维 sin/cos）。量化时计算余弦相似度，阈值≥0.92。支持残差存储。 |
| **token.zig** | Token 系统。Token ≤512B（编译期 @sizeOf 守卫），MAX_TOKEN_DIM=100。TokenType：Text（UTF-8 文本，64B）/ VectorQuantized（向量数据）。TokenSequence：[256]Token。 |
| **inference.zig** | 推理引擎。优先 Ollama 本地推理（当前为模拟实现，返回 error.OllamaNotAvailable）。OpenAI 路径标记为 WIP。 |
| **inference_client.zig** | Ollama 客户端存根。WIP 状态，硬编码返回 error.OllamaNotAvailable。等待 Zig 0.17 HTTP Client API 稳定后实现完整 /api/generate 调用。 |

### L3 — 路由层

**职责**：请求路由分发，多策略路由表匹配，向量检索加速。

| 组件 | 功能详解 |
|------|----------|
| **router.zig** | 请求路由层。根据报头 op_code 将请求分发给对应 HandlerFn。支持同步 HandlerFn(*RequestContext) 和异步 AsyncHandlerFn（含 cancel_token）。仅依赖 core 和 storage。 |
| **route_table.zig** | 多策略路由表。MAX_RULES=256，支持三种策略：exact（完全匹配）/ prefix（前缀匹配）/ fallback（兜底，权重最低）。线性扫描 O(n)，零堆分配。 |
| **comptime_router.zig** | 编译期路由生成。零运行时开销，编译期展开为完美 switch。RouteContext 替代 *anyopaque，编译期类型安全。自动检测重复 op_code（@compileError）。 |
| **vector_index.zig** | IVF+PQ 混合向量索引。DIM=256，MAX_VECTORS=64，NLIST=4（倒排桶），M=8（PQ子空间），KSUB=16（每子空间中心数）。支持增量 add，自动触发 K-Means 训练（最大10轮）。静态内存零堆分配。 |

### L4 — 执行层（无菌室）

**职责**：io_uring 底层 I/O，事件驱动状态机，协议解析。无菌室文件禁止 try/catch/orelse。

| 组件 | 功能详解 |
|------|----------|
| **io_uring.zig** | io_uring 封装。Ring（SQ_DEPTH=1024，编译期 2^n 校验）、SQE/CQE 结构体、Syscall 模块（socket/bind/listen/accept/send/recv/openat/write/read/close/register_buffers/mmap等）。Iovec 16字节编译期守卫。 |
| **reactor.zig** | Reactor 盲盒层。延迟提交：SQE 累积到 BATCH_THRESHOLD（默认8，编译期可配置）时自动 flush。Event 类型：IoComplete（user_data/result/buf_ptr）/ Idle。prepare_accept/prepare_send/prepare_recv 封装。 |
| **protocol.zig** | 5 状态机。Idle→HeaderRecv→BodyRecv→BodyDone→SendDone→WaitRequest（Keep-Alive）→Idle。13字节头部 DMA 流 ID 校验。BodyDone 时零拷贝转发到 BodyBufferPool。禁止 try/catch/orelse（第三诫）。 |

### L5 — 存储层

**职责**：请求数据缓冲，热度追踪，冷热数据分级持久化。

| 组件 | 功能详解 |
|------|----------|
| **storage.zig** | 物理存储池。StreamWindow（64槽 TokenStreamHeader 数组，push_header/access_header/release_header，swap-with-last 释放）+ BodyBufferPool（1024槽×4096B，write_offsets 追踪写入位置，slot_idx = stream_id % 1024）。 |
| **heat_pool.zig** | 热度池。64槽 u16 热度值。访问时：heat=100（首次）或 heat+log(heat+1.5)*0.75。衰减时：heat*=(1-(0.00035+0.012/(heat+2.0)))。范围 [0, 65535]。热度高的槽位优先持久化/保留。 |
| **ssd_persist.zig** | SSD 持久化。flush_heat_pool 序列化热度池到 /tmp/zigclaw_heat.bin（小端字节序），load_heat_pool 反序列化。当前为简化版（单文件覆盖），v3.0 计划实现真·双版本原子切换。 |
| **file_store.zig** | 文件存储后端。io_uring.Syscall 文件 I/O（openat/write/read/close），零堆分配。文件格式：纯二进制 HeatPool heats 数组字节表示。路径：/tmp/zigclaw_heat_pool.bin。 |

### L6 — 观测层

**职责**：系统内省，指标暴露，反馈学习闭环。

| 组件 | 功能详解 |
|------|----------|
| **ibus.zig** | I-Bus 内省总线。5层原子指标（Entry/Orch/Exec/Router/Storage），Mutex 保护全局变量。formatBusStatus() 遍历所有原子变量格式化为 JSON。emit() 日志事件。 |
| **feedback.zig** | 层指标契约。Layer 枚举（entry/orchestrator/execution/router/storage），LayerMetrics union（每层不同指标结构），Action/Suggestion 类型。纯类型锚点，零运行时开销。 |
| **feedback_engine.zig** | SimpleLearner 规则引擎。5条硬编码规则：R1 ring_full>10→enable_sq_poll / R2 route_miss>hit*0.2→扩容路由表 / R3 heat_miss>heat_hit→扩容热度池 / R4 syscall_fallback>5→adjust_timeout / R5 error_rate>5%→adjust_timeout。纯函数，无堆，不修改输入。 |

### 契约层

**职责**：编译期接口契约验证，层间类型锚点。

| 组件 | 功能详解 |
|------|----------|
| **interface.zig** | 纯类型锚点。ExecutorInterface（Op/Event/VTable）、StorageInterface（get/set VTable）、OrchestratorInterface（orchestrate VTable）。ContractVerifier 编译期验证：checkStorage/checkExecutor/checkOrchestrator，检查完整函数签名（参数类型+返回类型+ErrorSet 子集）。 |
| **feedback.zig** | 观测层契约。Layer/LayerMetrics/Action/Suggestion 类型定义，为 v3.0 大模型接入提供类型锚点。 |

---

## 🧪 测试体系

- **测试统计**：**153/153 全绿** ✅
- **核心模块内联测试**：`token` / `quantizer` / `heat_pool` / `vector_index` / `ibus` / `feedback_engine` / `comptime_router` / `app_router` 等
- **集成测试**：P3–P60 + `comptime_router` + `app_router` + **错误注入（`fault_injection`）**
- **编译期守卫**：`SyscallError` 完整性、`Ring.init` 返回类型、`AlignedAtomicU64` 对齐、`ConnSlot` 大小等

---

## 🚀 快速开始

### 环境要求

- **Zig**：0.16.0
- **系统**：Linux with `io_uring`（Kernel ≥ 5.1）

### 关键命令

```bash
# 克隆仓库
git clone git@github.com:CWLtoken/ZigClaw-AI.git
cd ZigClaw-AI

# 切换到 agent 分支（如需要）
git checkout agent

# 运行全部测试
zig build test

# 编译期配置（自定义 BATCH_THRESHOLD）
zig build -Dbatch_threshold=16

# 构建并运行
zig build run
```

---

## 📋 军规与约束（摘要）

1. **第一诫：精确导入**
   ✅ `const mem = @import("std").mem;`
   ❌ `const std = @import("std");`（非测试文件）

2. **第二诫：无菌室原则**
   无菌室文件（`reactor.zig`、`io_uring.zig`、`protocol.zig`）禁止 `try/catch/orelse`，必须显式 `if-else` 错误处理。

3. **第三诫：零第三方库**
   全部使用 Zig 0.16 标准库，禁用任何第三方依赖。

4. **第四诫：静态分配优先 + 依赖引入评审**

5. **第五诫：CI 必须 ReleaseSafe + 军规检查**

6. **第六诫：构建系统军规**
   使用 `addLibrary` + `addCSourceFile`，禁止 `addSystemCommand`；编译期配置通过 `b.option` + `addOptions` 注入。

7. **第七诫：类型安全（v3.3 新增）**
   ❌ `val as usize`（整数→usize 转换）→ ✅ `@as(usize, @intCast(val))`
   ❌ `const a, _ = fn()`（struct tuple 逗号解包）→ ✅ `const s = fn(); const a = s[0];`

---

## 📈 演进路线：Zig 0.17 + LongCat 正式发布

> 从 v3.4.1 军规基线出发，后续演进聚焦两条主线：**Zig 0.17 迁移** 与 **LongCat 正式发布**。

1. **Zig 0.17 迁移**
   - 在 0.17 下重新验证军规：显性直白 / 无菌室 / 无依赖0。
   - 适配新标准库与构建系统变更，确保 `io_uring` + `comptime` 路由等特性不变。
   - 目标：在 0.17 上达到与 0.16 相同的军规执行度与测试覆盖率。

2. **LongCat 正式发布**
   - 编排层：从"多模型向量提取 + LongCat"升级为 **统一离散 Token**，将连续向量通过码本强制离散化，实现文本/图像/视频统一上下文窗口。
   - 路由层：继续强化 IVF+PQ 256 维向量检索，保持静态内存零堆分配特性。
   - 观测层：将 IBus 反馈数据与 LongCat 调度策略深度结合，形成更紧密的学习飞轮。

3. **性能与可靠性深化**
   - 引入更完整的错误注入与性能回归 CI，覆盖 io_uring 失败、磁盘满、网络中断等极端场景。
   - 在高并发场景下持续压测 `reactor` + `connection_pool` 的延迟与稳定性。

---

## 🤝 贡献指南（精简）

1. **遵循军规**：无菌室 + 精确导入 + 零第三方库。
2. **测试驱动**：新功能必须附带测试，保持全绿。
3. **分层设计**：明确层级归属，禁止循环依赖。
4. **错误注入**：新增核心路径必须覆盖错误场景。

提交规范建议：`<type>(<scope>): <subject>`，例如：
- `feat(orchestrator): add unified discrete token support`
- `fix(reactor): make flush call sites explicit`
- `test(vector_index): add ivf+pq boundary tests`

---

## 📜 许可证

MIT License。详见 [LICENSE](LICENSE) 文件。

---

**ZigClaw-AI** — *从 io_uring 泥泞层到智能编排层，每一行都经过第一性原理优化。v3.4.1 军规全面合规，153/153 测试全绿。*
