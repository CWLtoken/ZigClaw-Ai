# ZigClaw-AI 🦅

[![Build Status](https://img.shields.io/badge/tests-136%2F136%20passed-brightgreen)](https://github.com/CWLtoken/ZigClaw-AI)
[![Zig Version](https://img.shields.io/badge/zig-0.16.0-blue)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![GitHub tag](https://img.shields.io/github/v/tag/CWLtoken/ZigClaw-AI?label=version)](https://github.com/CWLtoken/ZigClaw-AI/releases)

**ZigClaw-AI** 是一个基于 **Zig 0.16** 构建的高性能异步 AI 客服系统框架。采用 io_uring 底层、事件驱动架构和六层静态分层设计，严格遵守"零第三方库、零动态分配、显性直白"三大军规。

> **当前状态：v6.4.0-v3-final — v3.0 封板**  \
> 测试状态：**136/136 全绿** ✅ | 标签：`v6.4.0-v3-final`

---

## 🎯 核心特性

| 特性 | 描述 |
|------|------|
| **🚀 io_uring 零拷贝 I/O** | 基于 Linux io_uring，批量提交、链式操作、固定缓冲区注册 |
| **🧠 多模态编排** | 文本直通 + 向量量化，子脑注册表按模态调度 |
| **📊 IVF+PQ 向量检索** | 256 维向量 IVF 倒排索引 + 乘积量化，静态内存 |
| **🔍 内省总线** | IBus 5 层指标原子记录 + JSON 零堆序列化 |
| **🔄 反馈学习引擎** | SimpleLearner 硬编码规则，实时生成优化建议 |
| **💾 文件存储后端** | FileStore 基于 io_uring.Syscall 文件 I/O，零堆分配 |
| **🧪 136/136 全绿** | 覆盖六层架构全链路 + 集成测试 |

---

## 🏗️ 架构总览（六层静态分层）

```
┌──────────────────────────────────────────────────────────┐
│              入口与服务层 (Entry & Service Layer)          │
│  main.zig · server.zig · http_server.zig                  │
│  inference_client.zig · http_protocol.zig · http_log.zig  │
│  context.zig · entry/middleware.zig · entry/json_extractor│
│  metrics.zig · async_coordinator.zig                      │
│  • HTTP 服务（路由分发、健康检查、/ibus 端点）             │
│  • 推理客户端（OpenRouter/Ollama 接入）                   │
│  • 多租户上下文（X-Tenant-ID 解析）                       │
│  • 请求日志（结构化 JSON）                                │
├──────────────────────────────────────────────────────────┤
│                编排层 (Orchestration Layer)               │
│  orchestrator.zig · token.zig · quantizer.zig             │
│  sub_brain.zig · inference.zig                            │
│  • 多模态输入 → Token 序列 → 推理引擎                    │
│  • 文本直通（零量化开销）                                 │
│  • 向量量化（LCG 码本，余弦相似度 ≥ 0.92）               │
│  • 子脑注册表（最大 8 个，按模态分发）                    │
├──────────────────────────────────────────────────────────┤
│                 路由层 (Router Layer)                     │
│  route_table.zig · vector_index.zig · router.zig          │
│  • 多策略路由：精确匹配 + 前缀匹配 + Fallback             │
│  • IVF+PQ 向量索引（nlist=4, M=8, KSUB=16）             │
│  • 静态路由表（权重优先级，零堆分配）                     │
├──────────────────────────────────────────────────────────┤
│                执行层 (Execution Layer)                   │
│  io_uring.zig · reactor.zig · protocol.zig · core.zig     │
│  • io_uring Ring（SQE/CQE 1:1 内存镜像）                 │
│  • Reactor 盲盒层（prepare_recv/send）                    │
│  • 协议状态机（5 状态，无 try/catch）                     │
├──────────────────────────────────────────────────────────┤
│                存储层 (Storage Layer)                     │
│  heat_pool.zig · ssd_persist.zig · storage.zig            │
│  file_store.zig                                           │
│  • HeatPool 热度池（动态分段指数衰减，64 槽）             │
│  • SSD 持久化（双版本页原子切换）                         │
│  • FileStore（io_uring.Syscall 文件 I/O）                 │
├──────────────────────────────────────────────────────────┤
│              观测层 (Observability Layer)                 │
│  ibus.zig · feedback_engine.zig · feedback.zig            │
│  interface.zig                                            │
│  • IBus 内省总线（LayerMetrics 原子变量 + JSON 格式化）   │
│  • SimpleLearner 反馈学习（5 条硬编码规则）               │
│  • StorageInterface / ExecutorInterface 契约             │
└──────────────────────────────────────────────────────────┘
```

---

## 📁 项目结构（按代码层级）

```
src/
│
├── 入口与服务层（Entry & Service Layer）
│   ├── main.zig                 # 程序入口，初始化 + 优雅关闭
│   ├── server.zig               # TCP 脚手架（无菌室，不导入 Protocol/Reactor）
│   ├── http_server.zig          # HTTP 服务：/health /v1/infer /metrics /ibus
│   ├── http_protocol.zig        # HTTP 协议辅助
│   ├── http_log.zig             # 结构化请求日志（JSON 行格式）
│   ├── inference_client.zig     # OpenRouter/Ollama 推理客户端
│   ├── async_coordinator.zig    # 异步协调器
│   ├── context.zig              # 请求上下文（原子 ID + tenant_id）
│   ├── metrics.zig              # Prometheus 格式指标
│   └── entry/
│       ├── middleware.zig        # 鉴权中间件
│       └── json_extractor.zig   # JSON 字段提取
│
├── 编排层（Orchestration Layer）
│   ├── orchestrator.zig         # 子脑注册表 + 编排主逻辑
│   ├── token.zig                # Token / TokenSequence（≤512B 编译期守卫）
│   ├── quantizer.zig            # 向量量化器（LCG 码本，256 中心）
│   ├── sub_brain.zig            # 子脑接口（文本/图像/音频）
│   └── inference.zig            # 推理引擎（模拟实现）
│
├── 路由层（Router Layer）
│   ├── route_table.zig          # 多策略路由（精确 + 前缀 + 权重优先级）
│   ├── vector_index.zig         # IVF+PQ 向量索引
│   └── router.zig               # 路由辅助
│
├── 执行层（Execution Layer）
│   ├── io_uring.zig             # io_uring Ring + Syscall（AT_FDCWD/openat/write/read）
│   ├── reactor.zig              # Reactor 盲盒层（无 std/storage 导入）
│   ├── protocol.zig             # 协议状态机（无 try/catch/orelse）
│   └── core.zig                 # 核心辅助
│
├── 存储层（Storage Layer）
│   ├── heat_pool.zig            # 热度池（64 槽，动态分段指数衰减）
│   ├── ssd_persist.zig          # SSD 持久化（双版本页原子切换）
│   ├── storage.zig              # StreamWindow 存储
│   └── file_store.zig           # 文件存储后端（openat/write/read）
│
├── 观测层（Observability Layer）
│   ├── ibus.zig                 # IBus 内省总线（LayerMetrics + formatBusStatus）
│   ├── feedback_engine.zig      # SimpleLearner 反馈学习引擎
│   ├── feedback.zig             # Layer / LayerMetrics / Learner / Suggestion 类型契约
│   └── interface.zig            # ExecutorInterface / StorageInterface / OrchestratorInterface
│
├── 集成测试（Integration Tests）
│   ├── integration_p3.zig       # Phase 3  ：Ring 基础
│   ├── integration_p4.zig       # Phase 4  ：批量提交
│   ├── integration_p5.zig       # Phase 5  ：链式操作
│   ├── integration_p6.zig       # Phase 6  ：错误恢复
│   ├── integration_p7.zig       # Phase 7  ：固定缓冲区
│   ├── integration_p8.zig       # Phase 8  ：多区间注册
│   ├── integration_p9.zig       # Phase 9  ：SOCKET 操作
│   ├── integration_p10.zig      # Phase 10 ：ACCEPT+SEND/RECV
│   ├── integration_p11.zig      # Phase 11 ：FD 注册
│   ├── integration_p12.zig      # Phase 12 ：FSYNC 链
│   ├── integration_p13.zig      # Phase 13 ：Reactor prepare 接口
│   ├── integration_p14.zig      # Phase 14 ：Reactor 双向引擎
│   ├── integration_p15.zig      # Phase 15 ：Protocol 状态机
│   ├── integration_p16.zig      # Phase 16 ：Protocol 压力测试
│   ├── integration_p17.zig      # Phase 17 ：编排层集成
│   ├── integration_p18.zig      # Phase 18 ：子脑注册 + 模态分发
│   ├── integration_p19.zig      # Phase 19 ：全链路推理
│   ├── integration_p20.zig      # Phase 20 ：图像子脑（LCG 256 维）
│   ├── integration_p21.zig      # Phase 21 ：HTTP 服务
│   ├── integration_p22.zig      # Phase 22 ：故障注入
│   ├── integration_p23.zig      # Phase 23 ：压力测试
│   ├── integration_p24.zig      # Phase 24 ：六层端到端
│   ├── integration_p25.zig      # Phase 25 ：六层全链路
│   ├── integration_p26.zig      # Phase 26 ：六层压力
│   ├── integration_p30.zig      #          ：infer_from_tokens 全链路
│   ├── integration_p31.zig      #          ：图像子脑全链路
│   ├── integration_p32.zig      #          ：Ollama 端到端
│   ├── integration_p33.zig      #          ：HTTP 推理服务
│   ├── integration_p34.zig      #          ：多模态推理
│   ├── integration_p35.zig      #          ：客服场景闭环
│   ├── integration_p36.zig      #          ：Protocol HTTP 推理
│   ├── integration_p37.zig      #          ：多连接压力
│   ├── integration_p38.zig      #          ：可观测性
│   ├── integration_p39.zig      #          ：故障注入与恢复
│   ├── integration_p40.zig      #          ：可观测性指标
│   ├── integration_p41.zig      #          ：故障注入与恢复
│   ├── integration_p47.zig      #          ：入口层加固
│   ├── integration_p48.zig      #          ：Metrics 基线
│   ├── integration_p49.zig      #          ：推理延迟直方图
│   ├── integration_p50.zig      #          ：请求日志
│   ├── integration_p51.zig      #          ：多实例部署
│   ├── integration_p52.zig      #          ：路由增强（精确/前缀/Fallback）
│   ├── integration_p53.zig      #          ：多租户上下文
│   ├── integration_p54.zig      # DRD-057  ：IVF+PQ 向量索引
│   ├── integration_p55.zig      # DRD-058  ：IBus 内省总线
│   ├── integration_p56.zig      # DRD-059  ：SimpleLearner 反馈学习
│   └── integration_p57.zig      # DRD-059  ：FileStore 文件存储
│
└── tests.zig                    # 统一测试入口（136 测试全绿）
```

---

## 🧪 测试体系

### 测试统计
- **总计**：**136/136** 全绿 ✅
- **核心模块内联测试**：token / quantizer / heat_pool / ssd_persist / vector_index / ibus / feedback_engine 等
- **集成测试**：P3–P57

### 关键测试一览

| 测试 | 验证点 | 所属层 |
|------|--------|--------|
| `token: 尺寸 ≤ 512 字节` | 编译期守卫 | 编排层 |
| `quantizer: 1000 组随机向量` | 余弦相似度 ≥ 0.92 | 编排层 |
| `heat_pool: 动态分段指数衰减` | 访问递增 + 未访问衰减 | 存储层 |
| `vector_index: IVF+PQ add+search` | 正交向量精确检索 | 路由层 |
| `vector_index: PQ MSE < 0.1` | 量化可逆性 | 路由层 |
| `ibus: formatBusStatus JSON` | 5 层指标 JSON 输出 | 观测层 |
| `feedback_engine: SQPOLL 建议` | ring_full > 10 触发规则 | 观测层 |
| `file_store: save/load 一致性` | 热度池持久化往返 | 存储层 |
| `file_store: 文件大小=128` | HeatPool.heats 字节对齐 | 存储层 |
| `http_server: /health` | 健康检查 + verbose | 入口层 |
| `http_server: /v1/infer` | 鉴权 + 推理 + 503 | 入口层 |
| `http_server: /ibus` | 内省总线端点 | 入口层 |
| `route_table: 精确/前缀/Fallback` | 多策略路由 | 路由层 |
| `context: X-Tenant-ID 解析` | 多租户上下文 | 入口层 |
| `integration_p51: 多实例部署` | 两实例独立响应 | 入口层 |

---

## 🚀 快速开始

### 环境要求
- **Zig**：0.16.0（安装路径 `/opt/zig-bin-0.16.0`）
- **系统**：Linux with io_uring（Kernel ≥ 5.1）
- **构建工具**：Zig 自带构建系统

### 构建与测试
```bash
# 克隆仓库
git clone git@github.com:CWLtoken/ZigClaw-AI.git
cd ZigClaw-AI

# 切换到 agent 分支
git checkout agent

# 运行全部测试（136/136）
zig build test

# 或手动指定
zig test src/tests.zig src/image_feature.c -ODebug --library c
```

---

## 📋 军规与约束

### 第一诫：精确导入
```zig
// ✅ 正确
const mem = @import("std").mem;
const math = @import("std").math;

// ❌ 禁止：仅允许测试文件 const std = @import("std")
const std = @import("std");
```

### 第二诫：无菌室原则
| 模块 | 禁止导入 | 禁止操作 |
|------|----------|----------|
| `reactor.zig` | std / storage / mem | mem.writeInt |
| `protocol.zig` | — | try / catch / orelse / ? |
| `server.zig` | Protocol / Reactor | 持有 Storage 指针 / std.Thread |

### 第三诫：零第三方库
全部使用 Zig 0.16 标准库，禁用任何第三方依赖。

### 第四诫：静态分配优先
编排层 / 路由层 / 观测层核心路径零堆分配，全部使用静态数组。

### 第五诫：CI 必须 ReleaseSafe
`zig build test -OReleaseSafe` 通过方可合并。

---

## 📈 演进路线

### 已完成（v6.4.0-v3-final — v3.0 封板）

| 版本 | DRD | 交付内容 | 测试增量 |
|------|-----|----------|----------|
| v6.0.3 | DRD-055 | DRD-055 封板（8 修复 + 2 蓝图） | 基线 |
| v6.1.0 | DRD-056 | V1 多策略路由 + V6 多租户上下文 | +6 → 122 |
| v6.2.0 | DRD-057+058 | V2 IVF+PQ 向量索引 + V3 IBus 内省总线 | +6 → 128 |
| v6.3.0 | DRD-059 | V4 SimpleLearner 反馈学习 + V5 FileStore | +8 → 136 |
| **v6.4.0** | **DRD-060** | **v3.0 最终封板** | **136/136 全绿** |

### v3.0 架构交付清单

| 编号 | 名称 | 核心文件 | 状态 |
|------|------|----------|------|
| V1 | 多策略路由 | route_table.zig, middleware.zig, context.zig | ✅ |
| V2 | IVF+PQ 向量索引 | vector_index.zig | ✅ |
| V3 | IBus 内省总线 | ibus.zig | ✅ |
| V4 | 观测反馈学习 | feedback_engine.zig | ✅ |
| V5 | 存储外置适配 | file_store.zig | ✅ |
| V6 | 多租户上下文 | context.zig | ✅ |

### 后续计划（v3.1+ 维护版本）

| 任务 | 所属层 | 说明 |
|------|--------|------|
| Keep-Alive 连接池 | 执行层 | HTTP 连接复用，非架构骨架，优先级低 |
| 真实图像/音频子脑 | 编排层 | 需要特征提取算法 |
| TLS/HTTPS 推理接入 | 执行层 | Zig 0.17 std.crypto.tls 稳定后 |
| Redis Store | 存储层 | FileStore 的下一步，需要 Redis 依赖 |

---

## 🤝 贡献指南

### 开发流程
1. **遵循军规**：无菌室 + 精确导入 + 零第三方库
2. **测试驱动**：新功能必须附带测试，保持全绿
3. **分层设计**：明确层级归属，禁止循环依赖
4. **增量提交**：每次 commit 附测试结果

### 提交规范
```
<type>: <description>

详细说明...
测试状态：X/X 全绿
```

类型：`feat(v<ver>):`（功能）、`fix:`（修复）、`docs:`（文档）

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

**ZigClaw-AI** — *从 io_uring 泥泞层到智能编排层，每一行都经过第一性原理优化。v3.0 封板。*
