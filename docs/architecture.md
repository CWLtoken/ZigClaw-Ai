# ZigClaw-AI 架构文档（六层静态分层 v6.9）

> 基于架构师 **DRD-039** 五层架构设计，经 P42-P46 模块对齐、F2+F3 前瞻交付、全局军规修复后，形成六层静态分层 + 入口与服务层的完整架构。
> **v6.9 更新**：二进制指标协议（ibus）+ 编译期契约验证（interface）+ 军规合规修复。

## 🏛 架构概览（含入口与服务层）

```
┌─────────────────────────────────────────────────────┐
│        入口与服务层 (Entry & Service Layer)          │
│  main.zig + server.zig + http_server.zig         │
│  + inference_client.zig                          │
│  • HTTP 服务（路由分发、健康检查）                │
│  • 推理客户端（OpenRouter/Ollama 接入）          │
│  • 主入口（初始化、优雅关闭）                    │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│          编排层 (Orchestration Layer)               │
│  orchestrator.zig + token.zig + quantizer.zig     │
│  + sub_brain.zig + inference.zig                  │
│  • 多模态输入 → Token 序列 → 推理引擎            │
│  • 文本直通（零量化开销）                         │
│  • 向量量化（余弦相似度 ≥ 0.92）                │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│           路由层 (Router Layer)  [NEW P44-P45]   │
│  router.zig + vector_index.zig + route_table.zig│
│  • 向量索引：256-dim 余弦相似度搜索             │
│  • 路由表：op_code → HandlerFn 映射 (256槽)     │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│          执行层 (Execution Layer)                │
│  protocol.zig + reactor.zig + io_uring.zig      │
│  • 协议状态机（5状态）                          │
│  • Reactor 盲盒层（prepare_recv/send）          │
│  • io_uring 泥泞层（Ring 真实化）              │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│          存储层 (Storage Layer)  [NEW P42-P43]   │
│  storage.zig + epoch.zig + heat_pool.zig       │
│  + ssd_persist.zig                             │
│  • StreamWindow 存储 + Epoch 回收              │
│  • HeatPool 热度池（动态分段指数衰减）          │
│  • SSD 持久化（双版本页原子切换）              │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│       观测层 (Observability Layer)  [NEW P46]    │
│  ibus.zig                                      │
│  • ModelFeedback 指标收集                       │
│  • 读写 metrics.json（无堆分配）               │
└─────────────────────────────────────────────────┘
```

## 🚪 入口与服务层（Entry & Service Layer）

### 定义与职责
入口与服务层是系统的**对外接口层**，负责接收外部请求、路由分发、调用核心引擎，不属于五层核心引擎。

| 模块 | 路径 | 职责 | 测试 |
|------|------|------|------|
| Main | `src/main.zig` | 程序入口，初始化各层，优雅关闭 | 集成测试 |
| Server | `src/server.zig` | TCP 脚手架，不导入 Protocol/Reactor，不持有 Storage 指针 | P5-P7 |
| HTTP Server | `src/http_server.zig` | HTTP 路由分发、健康检查、推理接口 | P40-P41 |
| Inference Client | `src/inference_client.zig` | OpenRouter/Ollama 推理接入 | P11-P16 |

### 依赖规则（军规）
✅ **允许**：导入五层核心引擎的**公开接口**（如 `router.HandlerFn`、`orchestrator.Orchestrator`）
❌ **禁止**：导入五层核心引擎的**内部实现**（如 `reactor.zig`、`protocol.zig` 的内部结构）

### 与五层核心引擎的关系
- **入口层 → 编排层**：调用 `orchestrator.process()` 进行推理
- **入口层 → 路由层**：使用 `router.HandlerFn` 注册 HTTP 路由
- **入口层 → 执行层**：通过 `protocol.zig` 的公开 API 间接通信（不直接访问内部）
- **入口层 → 存储层/观测层**：独立，不直接依赖

---

## 📋 层间依赖规则（军规）

| 层 | 允许访问的层 | 禁止访问的层 |
|----|------------|------------|
| 编排层 | 路由层、执行层（通过接口） | 存储层、观测层内部结构 |
| 路由层 | 执行层（protocol.reactor） | 存储层、观测层 |
| 执行层 | 无（底层） | 上层所有层 |
| 存储层 | 无（独立） | 执行层、协议层（reactor.zig, protocol.zig） |
| 观测层 | 无（独立） | 执行层、协议层（reactor.zig, protocol.zig） |

**关键约束**：
- ✅ `protocol.zig` 通过 `self.reactor.prepare_recv(...)` 调用，不直接访问 `ring` 内部字段
- ✅ 存储层/路由层/观测层模块 **不导入** `reactor.zig` 或 `protocol.zig`
- ✅ 所有新模块使用 **静态分配**（无堆分配）

## 🗂️ 模块清单（按层）

### 编排层 (Orchestration Layer)
| 模块 | 路径 | 功能 | 测试 |
|------|------|------|------|
| Token | `src/token.zig` | Token 定义（Text/VectorQuantized） | P17 |
| Quantizer | `src/quantizer.zig` | 向量量化（256码本，余弦相似度≥0.92） | P17 |
| SubBrain | `src/sub_brain.zig` | 子脑接口（多模态输入） | P17 |
| Orchestrator | `src/orchestrator.zig` | 编排器（子脑调度→量化→输出） | P17 |
| Inference | `src/inference.zig` | 推理引擎（模拟实现） | P11-P16 |

### 路由层 (Router Layer) [P44-P45 新增]
| 模块 | 路径 | 功能 | 测试 |
|------|------|------|------|
| Router | `src/router.zig` | HTTP 路由（op_code → HandlerFn） | P5-P7 |
| VectorIndex | `src/vector_index.zig` | 向量索引（256-dim，暴力搜索） | P44 (2 tests) |
| RouteTable | `src/route_table.zig` | 路由表（256槽数组） | P45 (2 tests) |

### 执行层 (Execution Layer)
| 模块 | 路径 | 功能 | 测试 |
|------|------|------|------|
| Protocol | `src/protocol.zig` | 协议状态机（ACCEPT/CONN/RECV/SEND/CLOSE） | P5-P7, P16 |
| Reactor | `src/reactor.zig` | 事件驱动（prepare_recv/send/submit） | P13-P15 |
| io_uring | `src/io_uring.zig` | io_uring 封装（Ring/CQE/SQE） | P3-P12 |

### 存储层 (Storage Layer) [P42-P43 新增]
| 模块 | 路径 | 功能 | 测试 |
|------|------|------|------|
| Storage | `src/storage.zig` | StreamWindow 存储（静态分配） | P8-P10 |
| Epoch | `src/epoch.zig` | Epoch 回收（无锁内存管理） | P8-P10 |
| HeatPool | `src/heat_pool.zig` | 热度池（动态分段指数衰减） | P42 (3 tests) |
| SSDPersist | `src/ssd_persist.zig` | SSD 持久化（双版本页原子切换） | P43 (1 test) |

### 观测层 (Observability Layer) [P46 新增]
| 模块 | 路径 | 功能 | 测试 |
|------|------|------|------|
| IBus | `src/ibus.zig` | I-Bus（ModelFeedback 指标收集） | P46 (2 tests) |

## 🧪 测试统计

- **总计**：**86/86** 测试全绿 ✅
- **原有**：76 个测试（P3-P41）
- **新增**：10 个测试（P42-P46）
  - P42: 3 tests（HeatPool）
  - P43: 1 test（SSDPersist）
  - P44: 2 tests（VectorIndex）
  - P45: 2 tests（RouteTable）
  - P46: 2 tests（IBus）

## 🔧 关键技术细节

### 静态分配约束
所有模块使用固定大小数组，无堆分配：
```zig
// HeatPool: 64 个槽位
pub const HeatPool = struct {
    slots: [64]HeatSlot,
    ...
};

// VectorIndex: 64 个向量，256 维
pub const VectorIndex = struct {
    keys: [64][256]f32,
    ...
};

// RouteTable: 256 个槽位
pub const RouteTable = struct {
    slots: [256]?RouteEntry,
    ...
};
```

### 层间连接检查（步骤8）
✅ **通过**：`protocol.zig` 不直接访问 `self.reactor.ring` 内部字段
- 所有 ring 操作通过 `reactor.zig` 的 `prepare_recv`、`prepare_send` 方法
- 无循环依赖，符合无菌室原则

## 📈 演进路线

### 已完成（v5.6 五层架构对齐）
- ✅ P42-P46：存储层、路由层、观测层新模块
- ✅ 执行层注释标准化（protocol/reactor/io_uring）
- ✅ 86/86 测试全绿

### 后续计划（Phase 18+）
| 任务 | 所属层 | 阻塞因素 |
|------|--------|----------|
| `infer_from_tokens` 接口 | 编排层 | 无（阶段 18 任务） |
| 真实图像/音频子脑 | 编排层 | 特征提取算法 |
| TLS/HTTPS 推理接入 | 执行层 | Zig 0.17 `std.crypto.tls` 稳定 |
| Keep-Alive 连接复用 | 执行层 | 无阻塞 |

---

## 🔄 多副本部署边界（v6.5.0）

> **来源**：DRD-061 架构师审计 — "关键瓶颈在无状态化与多副本边界"

### 进程内状态清单

| 状态 | 位置 | 重启后可恢复 | 多副本共享 | 外置方案 |
|------|------|-------------|-----------|----------|
| HeatPool 热度值 | `heat_pool.zig` | ✅ ssd_persist 持久化 | ❌ 进程本地 | FileStore → Redis |
| StreamWindow 元数据 | `storage.zig` | ❌ 重建 | ❌ 进程本地 | 无 |
| BodyBufferPool 数据 | `storage.zig` | ❌ 重建 | ❌ 进程本地 | 无 |
| 子脑注册表 | `orchestrator.zig` | ❌ 静态注册 | ⚠️ 各副本独立 | 配置中心 |
| HTTP ServerMetrics | `http_server.zig` | ❌ 归零 | ❌ 进程本地 | Prometheus 聚合 |
| IBus LayerMetrics | `ibus.zig` | ❌ 归零 | ❌ 进程本地 | 独立端点暴露 |

### 无状态化边界

- **当前架构为单副本设计**。所有运行时状态（热度池除外）均在进程内存中，重启即丢失。
- **多副本部署时**：每个副本独立维护自己的 HeatPool、StreamWindow、Metrics。不存在共享内存或分布式锁。
- **外置存储路径**：`file_store.zig` 提供了文件级持久化基础。下一步可替换为 Redis Store，实现跨副本热度池共享。
- **推荐部署模式**：无状态前端（多副本）+ 有状态存储外置（Redis）。当前版本不支持，需 StorageInterface 实现升级。

### 契约层（v6.5.0 新增）

编译期契约验证确保各层接口一致性：

| 契约 | 验证位置 | 验证内容 |
|------|----------|----------|
| StorageInterface | tests.zig comptime | FileStore.vtable.get/set 为函数指针 |
| OrchestratorInterface | tests.zig comptime | Orchestrator 有 orchestrate 声明 |
| ExecutorInterface | tests.zig comptime | Reactor 有 submit/poll，Ring 有 deinit |

---

## ⚡ P2 性能优化军规（v6.7.0）

> **来源**：架构师终审 — "把 P2 优化从'实现细节'升级为'架构契约'"

### 缓存行对齐军规

**规则**：所有高频争用原子变量必须使用 `AlignedAtomicU64`，禁止裸 `std.atomic.Value(u64)`。

**原因**：消除伪共享（False Sharing），保证多核线性扩展。

**位置**：`metrics.zig` 中 `AlignedAtomicU64` 定义 + 所有全局原子变量声明。

```zig
pub const AlignedAtomicU64 = struct {
    value: std.atomic.Value(u64) align(CACHE_LINE),
    _pad: [CACHE_LINE - @sizeOf(std.atomic.Value(u64))]u8 = undefined,
    // ...
};
```

**检查点**：
- `metrics.zig` 中所有全局原子变量必须是 `AlignedAtomicU64`
- `ibus.zig` 中 `LayerMetrics` 结构体字段紧密排列（同结构体内伪共享风险低）

### io_uring 延迟提交军规

**规则**：Reactor 采用延迟提交策略，`BATCH_THRESHOLD=8`，`flush` 调用位置必须遵守：

1. `prepare_recv` / `prepare_send` 中 `pending_sqe_count >= BATCH_THRESHOLD` 时自动 flush
2. 进入 `poll` 前必须 flush
3. 其它地方禁止直接调用 flush，除非有特殊性能调优理由

**位置**：`reactor.zig` 中 `Reactor` 结构体顶部军规注释。

**原因**：减少 `io_uring_submit` 系统调用次数，同时保证不饿死 CQ。

### Comptime 路由军规

**规则**：路由表配置在编译期完成，运行时零查表开销。

**位置**：`comptime_router.zig`（通用框架）+ `entry/app_router.zig`（业务路由）。

**检查点**：
- `ComptimeRouter` 编译期检测重复 `op_code`
- `dispatch` 函数用 `inline for` 展开
- `RouteContext` 替代 `*anyopaque`，编译期类型安全

---

**架构版本**：v6.7.0-lts-final
**提交哈希**：待最终提交
**测试状态**：144/144 全绿 ✅（ReleaseSafe）
**最后更新**：2026-05-06
