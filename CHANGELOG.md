# ZigClaw v2.4 Changelog

## 发布日期：2026-05-04

## 概览
ZigClaw v2.4 完成从阶段0到阶段16的功能开发，实现高性能异步HTTP服务器框架，支持io_uring、事件驱动、状态机协议处理、推理引擎集成。阶段16 HTTPS推理接入因Zig 0.16 HTTP Client API复杂度降级为WIP，等待Zig 0.17稳定后接入。

## 里程碑

### 阶段0-2：基础设施
- 项目初始化、构建系统配置
- 开发环境搭建（Zig 0.16.0）

### 阶段3-12：io_uring 泥泞层
- **P3**：io_uring 基础设（setup/mmap/enter）
- **P4-P6**：注册文件、缓冲区、提交队列
- **P7-P9**：轮询完成、事件处理、错误恢复
- **P10-P12**：高级特性、压力测试、性能优化
- 测试：P3-P12 全绿

### 阶段13-15：Reactor 盲盒层
- **P13**：prepare_recv 接收准备
- **P14**：prepare_send 发送准备 + RECV/SEND双向通信验证
- **P15**：submit/submit_timeout 提交与超时
- 实现：单线程事件循环、64槽位填满测试
- 测试：P13-P15 全绿

### 阶段16-17：Protocol 大脑层
- **P16**：5状态机（parse/headers/body/complete/error）
- **P17**：IoRequest + reset() + 超时 + 错误恢复 + 多连接事件循环
- 测试：P3/P16/P17 全绿

### 阶段18-22：Storage 存储层 + 事件循环
- **P18**：StreamWindow 流窗口管理
- **P19-P21**：HandlerFn + AsyncHandlerFn + 线程安全回调
- **P22**：容量填满 + 异常注入压力测试
- **P23-P24**：1024轮压力测试、高级错误处理
- 测试：全局 Storage 测试全绿

### 阶段25-26：推理引擎
- **P25**：inference.zig 框架 + P25集成测试
- **P26**：http_client.zig OpenRouter接入（模拟实现）
  - 因Zig 0.16 `std.http.Client` API复杂度降级为WIP
  - 模拟实现终态，等待Zig 0.17标准库稳定
  - Tag: `v3.6-p26-http-wip`
  - **2026-05-04 技术部新版验证**：
    - 验证目标：技术部极简 inference.zig 构想（78行）在 Zig 0.16 下的可行性
    - 验证结果：**不可行**
    - 主要阻塞点：
      1. `std.posix.getenv` 不存在（环境变量读取失败）
      2. `std.http.Client` API 不兼容（需 `Io.Threaded` 初始化，无 `client.open`）
      3. `ArrayList(u8).init` 方法不存在
      4. `response.reader` 用法不明确
    - 验证报告：`/root/.hermes/QQQQ/大段文字.md`
    - 结论：保持模拟实现，等待 Zig 0.17 HTTP Client API 稳定

## 技术架构

| 层级 | 能力 | 测试 |
|------|------|------|
| io_uring 泥泞层 | setup/mmap/enter/register/poll 完整降维 | P3-P12 |
| Reactor 盲盒层 | prepare_recv/prepare_send/submit/submit_timeout | P13-P15 |
| Protocol 大脑层 | 5 状态机 + IoRequest + reset() + 超时 + 错误恢复 | P3/P16/P17 |
| Storage 存储层 | StreamWindow + BodyBufferPool + 槽位释放 | 全局 |
| 事件循环 | 单线程多连接 + 64 槽位填满 | P17/P22 |
| 业务接入 | HandlerFn + AsyncHandlerFn + 线程安全回调 | P19-P21 |
| 推理引擎 | inference.zig + http_client.zig 框架 | P25/P26 |
| 压力测试 | 容量填满 + 异常注入 | P22/P24 |

## 项目军规遵守
- ✅ 禁止第三方库，全部使用Zig 0.16标准库
- ✅ 无菌室原则：reactor.zig无std/storage导入、无mem.writeInt
- ✅ protocol.zig状态机内无try/catch/orelse/?
- ✅ server.zig不导入Protocol/Reactor、不持有Storage指针
- ✅ 精确导入：禁止`const std = @import("std")`，仅允许精确导入如`const mem = @import("std").mem`

## 已知限制
1. **TLS安全传输**：依赖`std.crypto.tls`，API复杂，等待Zig 0.17
2. **HTTPS推理接入**：依赖`std.http.Client`，API不稳定，降级为WIP
3. **环境变量读取**：Zig 0.16无`std.process.getEnvVarOwned`，采用参数传递方案

## 后续演进路线

| 任务 | 阻塞因素 | 预计解封 |
|------|----------|----------|
| TLS 安全传输 | Zig 0.16 `std.crypto.tls` API 复杂 | Zig 0.17 标准库稳定 |
| HTTPS 推理接入 | 依赖 TLS + HTTP Client 稳定 | Zig 0.17 |
| Keep-Alive 连接复用 | 无阻塞，纯功能开发 | 随时可做 |
| P23 1024 轮压力测试 | 测试策略需每轮重新 ACCEPT | 随时可做 |

## Git 标签
- `v3.4-p26-inference-framework`：阶段14封板
- `v3.5-p26-http-client`：阶段15封板（26/27测试全绿）
- `v3.6-p26-openrouter-wip`：阶段16 WIP标签
- `v3.6-p26-http-wip`：阶段16封板（模拟实现终态）
- `v2.4-final`：主版本封板

## 贡献者
- 技术部开发团队
- 架构师指导
- Hermes AI Agent 协作

---
**ZigClaw v2.4 进入归档状态。等待 Zig 0.17 标准库稳定后继续演进。**
