# ZigClaw-AI 架构文档（五层架构对齐 v5.8）

> 基于架构师 **DRD-039** 五层架构设计，完成 P42-P46 模块对齐。
> **v5.8 更新**：数学精度修正（f32→f64 显式转换）+ 入口与服务层文档补全。

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

**架构版本**：v5.6-five-layer  
**提交哈希**：46daba3  
**测试状态**：86/86 全绿 ✅  
**最后更新**：2026-05-06
