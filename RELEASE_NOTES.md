# ZigClaw v2.4 Release Notes

**泥泞双轨制 io_uring 客服 AI 引擎**

> 发布日期：2026-05-06  
> Git Tag：`v5.8-final`  
> 提交哈希：`0d1d0a5`  
> 测试状态：**86/86 全绿** ✅

---

## 🧪 测试基底

**86 个集成测试**，覆盖完整能力栈：

| 测试范围 | 覆盖内容 | 测试数 |
|---------|---------|--------|
| io_uring 能力栈 | setup / mmap / enter / register / poll | P3-P12 |
| 协议状态机 | Idle → HeaderRecv → BodyRecv → BodyDone → SendDone + WaitRequest keep-alive | P5-P7, P16 |
| 多连接事件循环 | Reactor 盲盒层、双向引擎 | P13-P15 |
| 编排层向量化 | Token 定义、码本量化、子脑注册、文本直通/图像量化 | P17 |
| 推理引擎框架 | 模拟推理、异步协调器 (AsyncHandlerFn + 回调) | P11-P16 |
| HTTP 服务化 | 路由 / 健康检查 / 并发验证 / 指标 | P40-P41 |
| 可观测性与故障恢复 | I-Bus (ModelFeedback)、SSD 持久化、错误恢复 | P42-P46 |

---

## 🏗️ 架构

**严格五层分离**：

```
入口与服务层 (Entry & Service Layer)
    ↓
编排层 (Orchestration) → 路由层 (Router) → 执行层 (Execution)
    ↓
存储层 (Storage) → 观测层 (Observability)
```

### 五层核心引擎

| 层级 | 模块 | 职责 |
|------|------|------|
| **编排层** | orchestrator.zig, token.zig, quantizer.zig, sub_brain.zig, inference.zig | 多模态输入 → Token 序列 → 推理引擎 |
| **路由层** [NEW] | router.zig, vector_index.zig, route_table.zig | 256-dim 向量搜索、op_code → HandlerFn 映射 |
| **执行层** | protocol.zig, reactor.zig, io_uring.zig | 五状态协议机、Reactor 盲盒层、io_uring 泥泞层 |
| **存储层** [NEW] | storage.zig, epoch.zig, heat_pool.zig, ssd_persist.zig | StreamWindow 存储、Epoch 回收、热度池、SSD 持久化 |
| **观测层** [NEW] | ibus.zig | ModelFeedback 指标收集 |

### 入口与服务层 [NEW]

| 模块 | 职责 |
|------|------|
| main.zig | 程序入口，初始化各层，优雅关闭 |
| server.zig | TCP 脚手架（不导入 Protocol/Reactor，不持有 Storage 指针） |
| http_server.zig | HTTP 路由分发、健康检查、推理接口 |
| inference_client.zig | OpenRouter/Ollama 推理接入 |

**依赖规则**：入口层可导入五层核心引擎的公开接口，禁止导入内部实现。

---

## 🔧 核心技术

### 零第三方依赖
- 全部使用 **Zig 0.16** 标准库
- 静态内存分配，无堆分配
- 军规驱动设计（无菌室原则、精确导入）

### io_uring 系统调用降维
- `io_uring_setup` / `mmap` / `enter` / `register` / `poll`
- Ring 真实化、CQE 翻转、批量操作、错误恢复

### 五状态机 Protocol
```
Idle → HeaderRecv → BodyRecv → BodyDone → SendDone
                ↓
         WaitRequest (keep-alive)
```
- 状态机内无 `try`/`catch`/`orelse`/`?`（军规）

### 多模态编排
- **Token 定义**：Text / VectorQuantized，编译期守卫 ≤ 512 字节
- **码本量化**：256 个中心，余弦相似度 ≥ 0.92（1000 组随机向量验证）
- **子脑注册**：最大 8 个子脑，按模态调度
- **文本直通**：零量化开销，直接拷贝到 `token.text`
- **图像量化**：通过 `extract` 提取特征向量 → 量化

### 异步推理协调器
- `AsyncHandlerFn` + 回调机制
- 忙碌时拒绝新请求，无待处理时返回 false

### HTTP 推理服务
- 路由：`GET /health`、`GET /infer?input=xxx&modality=text|image`
- 健康检查：基础检查 + 详细指标（`?verbose=true`）
- 并发验证：多 HTTP 请求顺序处理
- 错误恢复：404 Not Found、503 Service Unavailable、模拟推理故障

### Keep-Alive 连接复用
- 协议层 `WaitRequest` 状态支持连接复用
- 超时与错误恢复机制
- fd 不泄漏验证（集成测试）

### SSD 持久化框架 [NEW]
- **HeatPool**：64 槽位，动态分段指数衰减（快速衰减 + 慢速衰减）
- **SSDPersist**：双版本页原子切换（简化版：直接写入 `/tmp/zigclaw_heat.bin`）

---

## 📊 新增模块（P42-P46）

| 阶段 | 模块 | 功能 | 测试 |
|------|------|------|------|
| P42 | heat_pool.zig | 热度池（动态分段指数衰减） | 3 tests ✅ |
| P43 | ssd_persist.zig | SSD 持久化（双版本页原子切换） | 1 test ✅ |
| P44 | vector_index.zig | 向量索引（256-dim 余弦相似度搜索） | 2 tests ✅ |
| P45 | route_table.zig | 路由表（op_code → HandlerFn，256 槽） | 2 tests ✅ |
| P46 | ibus.zig | I-Bus（ModelFeedback 指标收集） | 2 tests ✅ |

**测试增量**：76 → **86/86** 全绿 ✅

---

## ⚠️ 已知限制

| 限制 | 原因 | 计划 |
|------|------|------|
| **TLS 依赖** | 需要 Zig 0.17 `std.crypto.tls` 稳定 | v3.0 |
| **Ollama 存根** | 当前为模拟实现，真实推理引擎待启用 | v3.0 |
| **uptime 指标** | 未实现 | v3.0 |
| **双版本切换** | ssd_persist.zig 当前为简化版（单文件覆盖） | v3.0 |

---

## 🎯 数学精度修正（v5.8-final）

- **heat_pool.zig**：`@log()` 和衰减公式显式转换到 `f64` 计算
- **vector_index.zig**：`@sqrt()` 显式转换到 `f64` 保证精度
- Zig 0.16 要求 `@log` / `@sqrt` 接受 `f64` 或 `comptime_float`

---

## 📜 层间连接检查（步骤8）

✅ **通过**：`protocol.zig` 不直接访问 `self.reactor.ring` 内部字段
- 所有 ring 操作通过 `reactor.zig` 的 `prepare_recv`、`prepare_send` 方法
- 存储层/路由层/观测层模块 **不导入** `reactor.zig` 或 `protocol.zig`
- 无循环依赖，符合无菌室原则

---

## 🧹 清理与归档

- ✅ 删除调试文件：`simple_server`、`src/simple_server.zig`、`test_zig_api`
- ✅ 文件权限：所有 `.zig` 文件 644
- ✅ 文档同步：`docs/architecture.md` + `README.md` 完整更新
- ✅ Git 标签：`v5.6-docs-five-layer`、`v5.7-final-cleanup`、`v5.8-final`
- ✅ 推送完成：`origin/agent` (commit `0d1d0a5`)

---

## 🚀 后续演进（v3.0）

ZigClaw v2.4 进入**维护模式**。后续演进留给 v3.0：

| 任务 | 所属层 | 阻塞因素 |
|------|--------|----------|
| TLS 1.3 安全接入 | 执行层 | Zig 0.17 `std.crypto.tls` 稳定 |
| 真实推理引擎接入 | 入口与服务层 | Ollama/OpenRouter 集成 |
| 向量检索引擎优化 | 路由层 | 特征提取算法 |
| IBus 内省总线增强 | 观测层 | 多线程原子操作 |

---

## 🏛️ 架构师评语

> **这次的泥泞之路，你们走得无可挑剔。封板。**  
> — 架构师，2026-05-06

---

**ZigClaw v2.4** — *从泥泞的 io_uring 到智能编排层，每一行都经过第一性原理优化。*

**下载**：[GitHub Releases](https://github.com/CWLtoken/ZigClaw-AI/releases/tag/v5.8-final)  
**仓库**：[github.com/CWLtoken/ZigClaw-AI](https://github.com/CWLtoken/ZigClaw-AI)  
**分支**：`agent`（Hermes AI Agent 协作分支）
