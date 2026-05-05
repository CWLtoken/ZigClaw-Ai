# ZigClaw v2.4 架构纠偏记录 (D1-D8)

> 本文档记录架构师对ZigClaw架构的纠偏决策，包含错误方案和正确方案的对比。

## D1: HTTP 服务器实现方式纠偏

### 错误方案
- 在 `http_server.zig` 中直接使用 `async_coordinator` 和 `orchestrator`
- 推理逻辑直接写在 HTTP 服务器中
- 导致 HTTP 服务器依赖过多模块，违反服务器隔离原则

### 正确方案
- HTTP 服务器仅负责 HTTP 协议解析和响应
- 推理功能通过 `http_protocol.zig` 中间层处理
- `http_server.zig` 仅依赖 `io_uring` 和 `std`（精确导入）
- **结果**: 阶段23B封板，HTTP和二进制协议并列

### 架构师裁决
> "通过 Protocol 状态机" = 遵循相同架构模式（Reactor + 状态机 + 异步 I/O）
> `http_protocol.zig` 直接使用 Reactor **是正确的**
> HTTP 和二进制协议是**并列关系**，不是替代关系

---

## D2: 原子操作使用纠偏

### 错误方案
- 使用 Zig 0.13 旧语法 `@atomicLoad` / `@atomicStore`
- 导致编译错误 `expected type 'bool', found 'type'`

### 正确方案
- 使用 Zig 0.16+ 新语法 `.load()` / `.store()` / `.rmw()`
- 示例：
  ```zig
  // 正确
  self.running.load(.acquire);
  self.running.store(false, .release);
  self.total_requests.rmw(.Add, 1, .acquire);
  ```

### 永久法则
✅ Zig 0.16+ 原子操作使用 `.load()` / `.store()` / `.rmw()` 方法

---

## D3: 时间戳 API 纠偏

### 错误方案
- 使用 `std.time.milliTimestamp()` 
- 导致编译错误 `root source file struct 'time' has no member named 'milliTimestamp'`

### 正确方案（临时）
- 暂时使用 `std.time.timestamp() * 1000` 或返回0（简化版）
- 等待 Zig 0.17 提供稳定的时间戳 API
- **架构师确认**: `uptime` 返回0是已知限制，不阻塞当前封板

### 永久法则
⚠️ Zig 0.16 时间API不稳定，生产环境需自己实现或等待0.17

---

## D4: 错误处理语法纠偏

### 错误方案
- 使用 `catch |_|` 丢弃错误捕获
- 导致编译错误 `discard of error capture; omit it instead`

### 正确方案
- 使用 `catch |err| { _ = err; ... }` 显式处理
- 或直接使用 `catch continue;` 等控制流

### 永久法则
✅ 当需要忽略错误但又要捕获时，用 `_ = err;` 消除警告

---

## D5: 未使用参数处理纠偏

### 错误方案
- 函数参数未使用，直接编译报错 `unused function parameter`

### 正确方案
- 在函数体内添加 `_ = self;` 或 `_ = parameter;`
- 显式消除未使用警告

### 永久法则
✅ 未使用的参数必须用 `_ = param;` 显式消除警告

---

## D6: 推理服务依赖处理纠偏

### 错误方案
- Ollama 不可用时，服务器崩溃或返回不友好的错误
- 未处理外部依赖的不可用情况

### 正确方案
- 捕获 Ollama 错误，返回 503 Service Unavailable
- 在日志中记录警告，但不中断服务
- 示例：`[default] (warn): Ollama 调用失败: error.OllamaNotAvailable，返回错误响应`

### 永久法则
✅ 外部依赖（Ollama）必须处理不可用情况，优雅降级

---

## D7: 模块依赖关系纠偏

### 错误方案
- `http_server.zig` 导入 `orchestrator` 和 `sub_brain`
- 导致循环依赖和模块耦合度过高

### 正确方案
- 遵循四层架构：HTTP Server → HTTP Protocol → Reactor → io_uring
- 推理相关功能通过独立的 `http_protocol.zig` 处理
- 保持 `http_server.zig` 的轻量级和独立性

### 架构师裁决
> 服务器层应保持独立，不直接依赖底层模块
> 使用中间层（http_protocol.zig）解耦

---

## D8: 测试覆盖率纠偏

### 错误方案
- 新功能（如ServerMetrics、优雅关闭）没有对应的集成测试
- 仅靠单元测试无法验证端到端行为

### 正确方案
- 每个新功能必须配套集成测试（P40、P41等）
- 集成测试覆盖：可观测性、故障注入、恢复测试
- 保持全量测试 76/76 全绿

### 永久法则
✅ 新功能必须配套集成测试，验证端到端行为

---

## 总结：架构纠偏速查表

| 编号 | 纠偏主题 | 关键决策 |
|------|----------|----------|
| D1 | HTTP实现方式 | HTTP和二进制协议并列，通过http_protocol.zig解耦 |
| D2 | 原子操作 | 使用Zig 0.16+新语法 `.load()`/`.store()` |
| D3 | 时间戳API | 暂时简化，等待Zig 0.17 |
| D4 | 错误处理语法 | 用 `_ = err;` 消除未使用警告 |
| D5 | 未使用参数 | 用 `_ = param;` 显式消除 |
| D6 | 外部依赖处理 | Ollama不可用返回503，优雅降级 |
| D7 | 模块依赖 | 保持HTTP Server独立性，避免循环依赖 |
| D8 | 测试覆盖率 | 新功能必须配套集成测试 |

---

**架构师签名**: 确认D1-D8纠偏已落地，阶段23C完成。
