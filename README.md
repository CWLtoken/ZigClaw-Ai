# ZigClaw-AI 🦅

[![Build Status](https://img.shields.io/badge/tests-41%2F41%20passed-brightgreen)](https://github.com/CWLtoken/ZigClaw-AI)
[![Zig Version](https://img.shields.io/badge/zig-0.16.0-blue)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![GitHub tag](https://img.shields.io/github/v/tag/CWLtoken/ZigClaw-AI?label=version)](https://github.com/CWLtoken/ZigClaw-AI/releases)

**ZigClaw-AI** 是一个基于 **Zig 0.16** 标准库构建的高性能异步 AI 客服系统框架，采用 **io_uring** 底层、事件驱动架构和分层状态机设计。本项目严格遵守"零第三方库"军规，全部使用 Zig 0.16 标准库实现。

> **当前状态：v2.4 已封板 (Phase 0-17 完成)**  
> 最新标签：`v4.0-p30-orchestrator` | 测试状态：**41/41 全绿** ✅

---

## 🎯 核心特性

| 特性 | 描述 |
|------|------|
| **🚀 高性能异步 I/O** | 基于 Linux `io_uring` 实现零拷贝、批量提交、链式操作 |
| **🧠 智能编排层** | 多模态输入 → Token 序列 → 推理引擎，支持文本直通和向量量化 |
| **📊 自适应内存管理** | 静态分配、epoch 回收、无堆分配（编排层） |
| **🔒 军规驱动设计** | 无菌室原则、精确导入、无循环依赖 |
| **🧪 测试全绿** | 41 个测试覆盖从 Ring 到编排层的全链路 |

---

## 🏗️ 技术架构（DRD-039 落地）

### 分层架构

```
┌─────────────────────────────────────────────────────┐
│                 业务接入层                        │
│  Router (router.zig) + HandlerFn/AsyncHandlerFn │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│              编排层 (Phase 17)                   │
│  Orchestrator → SubBrain → Quantizer → Token    │
│  • 文本直通（零量化开销）                        │
│  • 向量量化（余弦相似度 ≥ 0.92）               │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│              推理引擎层 (Phase 11-16)             │
│  Inference (inference.zig) + OpenRouter (WIP)   │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│           协议层 (Phase 5-7, 16-17)             │
│  Protocol (protocol.zig) 5 状态机              │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│          Reactor 盲盒层 (Phase 13-15)            │
│  prepare_recv/send + submit/submit_timeout      │
└───────────────────────┬─────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────┐
│        io_uring 泥泞层 (Phase 3-12)              │
│  Ring 真实化 + CQE 翻转 + 批量操作 + 错误恢复   │
└─────────────────────────────────────────────────┘
```

### 关键技术模块

#### 1. **Token 系统** (`token.zig`)
```zig
pub const Token = struct {
    tpe: TokenType,        // Text | VectorQuantized
    dim: u16,              // 有效维度 ≤ MAX_TOKEN_DIM(64)
    data: [64]f32,         // 向量量化数据
    text: [64]u8,          // 文本数据
    text_len: u8,
};
```
- **编译期守卫**：`@sizeOf(Token) ≤ 512` 字节
- **静态容器**：`TokenSequence` 最大 256 个 Token，无堆分配

#### 2. **量化器** (`quantizer.zig`)
- **码本**：256 个中心，确定性初始化
- **精度指标**：余弦相似度 ≥ 0.92（1000 组随机向量验证）
- **LCG 随机数**：自实现线性同余生成器（Zig 0.16 无 `std.rand`）

#### 3. **子脑接口** (`sub_brain.zig`)
```zig
const SubBrain = struct {
    name: []const u8,
    extract: fn(input: []const u8, output: []f32) !void,
    input_modality: Modality, // Text | Image | Audio
    dim: u16,
};
```
- **文本直通**：零量化开销，直接拷贝到 `token.text`
- **图像/音频**：通过 `extract` 提取特征向量 → 量化

#### 4. **编排器** (`orchestrator.zig`)
- **子脑注册表**：最大 8 个子脑，按模态调度
- **编排主逻辑**：选择子脑 → 提取 → 量化 → 输出 Token 序列
- **模态支持**：文本（直通）、图像（模拟）、音频（预留）

---

## 🧪 测试体系

### 测试统计
- **总计**：41 个测试全绿 ✅
- **阶段覆盖**：P3-P30（含 P28 LCG 修复）
- **测试类型**：单元测试、集成测试、压力测试、量化精度验证

### 关键测试
| 测试 | 验证点 | 状态 |
|------|--------|------|
| `token.test.Token: 尺寸 ≤ 512 字节` | 编译期守卫 | ✅ |
| `quantizer.test.1000组随机向量` | 余弦相似度 ≥ 0.92 | ✅ |
| `orchestrator.test.文本直通` | 零量化开销 | ✅ |
| `integration_p30.test.全链路验证` | 输入→编排→推理→输出 | ✅ |

---

## 🚀 快速开始

### 环境要求
- **Zig**：0.16.0（安装路径 `/opt/zig-bin-0.16.0`）
- **系统**：Linux with io_uring support (Kernel ≥ 5.1)
- **构建工具**：Zig 自带构建系统

### 构建与测试
```bash
# 克隆仓库
git clone https://github.com/CWLtoken/ZigClaw-AI.git
cd ZigClaw-AI

# 切换到 agent 分支
git checkout agent

# 运行全部测试
zig test src/tests.zig -ODebug --zig-lib-dir /opt/zig-bin-0.16.0/lib

# 构建（如果有的话）
zig build
```

### 项目结构
```
src/
├── core/               # 核心系统
│   ├── ring.zig       # io_uring Ring 封装
│   ├── reactor.zig    # 事件驱动 Reactor
│   └── protocol.zig  # 协议状态机
├── memory/            # 内存系统
│   ├── storage.zig   # StreamWindow 存储
│   └── epoch.zig     # Epoch 回收
├── ai/                # AI 相关
│   ├── inference.zig  # 推理引擎（模拟实现）
│   ├── orchestrator.zig # 编排层（Phase 17）
│   ├── token.zig     # Token 定义
│   ├── quantizer.zig # 量化器
│   └── sub_brain.zig # 子脑接口
└── tests.zig         # 统一测试入口
```

---

## 📋 军规与约束

本项目严格遵守以下军规（架构师强制执行）：

### 1. **无菌室原则**
- `reactor.zig`：无 `std`/`storage` 导入，无 `mem.writeInt`
- `protocol.zig`：状态机内无 `try`/`catch`/`orelse`/`?`
- `server.zig`：不导入 Protocol/Reactor，不持有 Storage 指针

### 2. **精确导入**
```zig
// ✅ 正确：精确导入
const mem = @import("std").mem;
const math = @import("std").math;

// ❌ 禁止：全局导入
const std = @import("std");
```

### 3. **零第三方库**
- 全部使用 Zig 0.16 标准库
- 禁止使用任何第三方依赖

### 4. **静态分配优先**
- 编排层无堆分配
- Token/TokenSequence 使用栈或静态数组

---

## 📈 演进路线

### 已完成（v2.4 封板）
- ✅ Phase 0-2：基础设施 + Ring 真实化
- ✅ Phase 3-12：io_uring 泥泞层（批量/链式/错误恢复）
- ✅ Phase 13-15：Reactor 盲盒层 + 双向引擎
- ✅ Phase 16-17：协议层 + 推理框架 + **编排层向量化**

### 后续计划（Phase 18+）
| 任务 | 阻塞因素 | 预计解封 |
|------|----------|----------|
| `infer_from_tokens` 接口 | 无（阶段 18 任务） | 随时可做 |
| 真实图像/音频子脑 | 特征提取算法 | 阶段 18+ |
| TLS/HTTPS 推理接入 | Zig 0.17 `std.crypto.tls` 稳定 | Zig 0.17 |
| Keep-Alive 连接复用 | 无阻塞 | 随时可做 |

---

## 🤝 贡献指南

### 开发流程
1. **遵循军规**：严格遵守无菌室、精确导入、零第三方库原则
2. **测试驱动**：新功能必须附带测试，保持 41+/41 全绿
3. **分层设计**：新增模块明确层级，避免循环依赖
4. **文档同步**：更新 CHANGELOG.md 和对应文档

### 提交规范
```
<type>: <description>

- 详细说明...
- 测试状态：X/X 全绿
```

类型：`P<phase>-<desc>`（阶段工作）、`fix:`（修复）、`docs:`（文档）、`test:`（测试）

---

## 📄 相关文档

- **架构设计**：[DRD-039 阶段17编排层设计](/root/.hermes/QQQQ/大段文字.md)
- **变更日志**：[CHANGELOG.md](CHANGELOG.md)
- **技术部验证**：[技术部新版 inference.zig 验证报告](/root/.hermes/QQQQ/大段文字.md)

---

## 📧 联系与反馈

- **项目仓库**：[github.com/CWLtoken/ZigClaw-AI](https://github.com/CWLtoken/ZigClaw-AI)
- **分支说明**：
  - `main`：稳定发布分支
  - `agent`：Hermes AI Agent 协作分支（当前分支）
  - `zigclaw-hermes`：本地开发分支（跟踪 `agent`）

---

## 📜 许可证

本项目采用 MIT 许可证。详见 [LICENSE](LICENSE) 文件。

---

**ZigClaw-AI** — *高性能 AI 客服系统框架，从泥泞的 io_uring 到智能编排层，每一行都经过第一性原理优化。*
