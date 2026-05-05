# ZigClaw v2.4 踩坑记录 (E1-E32)

> 本文档记录ZigClaw开发过程中的所有踩坑经验，含根因分析和永久法则。

## E1: Zig 0.16 `std.os.socket` 不存在
- **现象**: 编译报错 `root source file struct 'os' has no member named 'socket'`
- **根因**: Zig 0.16 重构了标准库，`std.os` 下的系统调用API发生变化
- **解决**: 使用 `io_uring.Syscall.socket()` 或直接系统调用封装
- **永久法则**: ⚠️ Zig 0.16+ 避免使用 `std.os` 下的旧API，优先使用项目封装的 `io_uring.Syscall.*`

## E2: `std.time.milliTimestamp()` 不存在
- **现象**: 编译报错 `root source file struct 'time' has no member named 'milliTimestamp'`
- **根因**: Zig 0.16 `std.time` 没有 `milliTimestamp()` API
- **解决**: 暂时使用 `std.time.timestamp() * 1000` 或返回0（简化版）
- **永久法则**: ⚠️ Zig 0.16 时间API不稳定，生产环境需自己实现或等待0.17

## E3: 原子操作语法变化
- **现象**: `error: expected type 'bool', found 'type'`
- **根因**: Zig 0.16 的 `std.atomic.Value` 使用 `.load()` / `.store()` 方法，不是 `@atomicLoad` / `@atomicStore`
- **解决**: 
  ```zig
  // 正确 (0.16+)
  self.running.load(.acquire);
  self.running.store(false, .release);
  
  // 错误 (旧语法)
  @atomicLoad(bool, &self.running, .acquire);
  ```
- **永久法则**: ✅ Zig 0.16+ 原子操作使用 `.load()` / `.store()` / `.rmw()` 方法

## E4: 未使用捕获 `catch |_|` 报错
- **现象**: `error: discard of error capture; omit it instead`
- **根因**: Zig 0.16 不允许 `catch |_|` 这种丢弃错误捕获的语法
- **解决**: 使用 `catch |err| { _ = err; ... }` 或 `catch continue;`
- **永久法则**: ✅ 当需要忽略错误但又要捕获时，用 `_ = err;` 消除警告

## E5: 未使用函数参数报错
- **现象**: `error: unused function parameter`
- **根因**: Zig 编译器严格检查未使用的参数
- **解决**: 在函数体内添加 `_ = self;` 或 `_ = parameter;`
- **永久法则**: ✅ 未使用的参数必须用 `_ = param;` 显式消除警告

## E6: `const std = @import("std")` 违反第一诫
- **现象**: 架构师审计不通过
- **根因**: 非测试文件禁止导入整个std，只能精确导入所需模块
- **解决**: 改为 `const mem = @import("std").mem;` 等精确导入
- **永久法则**: 🚨 **第一诫**：非测试文件禁止 `const std = @import("std")`

## E7: reactor.zig 无菌室违规
- **现象**: reactor.zig 中导入了 `std` 或 `storage`
- **根因**: reactor是盲盒层，应保持最小化依赖
- **解决**: 移除所有std/storage导入，仅使用 `io_uring` 和基础类型
- **永久法则**: 🚨 **第二诫**：reactor.zig 无菌室，无std/storage导入、无mem.writeInt

## E8: protocol.zig 状态机内使用 try/catch
- **现象**: 协议状态机中包含错误处理代码
- **根因**: 状态机应保持纯净，错误处理应由上层Reactor负责
- **解决**: 移除状态机内的 try/catch/orelse/?，改为返回错误码
- **永久法则**: 🚨 **第三诫**：protocol.zig 状态机内无 try/catch/orelse/?

## E9: HTTP 服务器依赖 Protocol/Reactor
- **现象**: http_server.zig 或 main.zig 导入了 protocol 或 reactor
- **根因**: 服务器层应保持独立，不直接依赖底层
- **解决**: 使用 http_protocol.zig 作为中间层，避免直接依赖
- **永久法则**: 🚨 **第四诫**：server.zig 不导入 Protocol/Reactor、不持有 Storage 指针、不使用 std.Thread

## E10: io_uring SQ/CQ 队列溢出
- **现象**: 大量请求后 io_uring 提交失败
- **根因**: SQ 队列满，未及时收割 CQE
- **解决**: 批量提交 + 每次循环收割所有完成事件
- **永久法则**: ✅ 每次事件循环必须收割所有 CQE，避免队列积压

## E11: fd 泄漏检测
- **现象**: 长时间运行后文件描述符耗尽
- **根因**: 连接关闭后未正确 close(fd)
- **解决**: 使用 `defer io_uring.Syscall.close(fd)` 或显式关闭
- **永久法则**: ✅ 所有打开的 fd 必须有明确的关闭路径

## E12: RSS 内存增长
- **现象**: 长时间运行后内存持续增长
- **根因**: 未释放分配的内存（Arena未deinit、buffer未释放）
- **解决**: 使用 Arena allocator + defer deinit()，或明确 free
- **永久法则**: ✅ 每次请求处理完必须释放相关内存

## E13: 推理引擎 Ollama 不可用处理
- **现象**: Ollama 未启动时报错，服务崩溃
- **根因**: 未处理推理服务的不可用情况
- **解决**: 捕获 Ollama 错误，返回 503 Service Unavailable
- **永久法则**: ✅ 外部依赖（Ollama）必须处理不可用情况，优雅降级

## E14: 多模态 Token 量化维度不匹配
- **现象**: 图像子脑输出64维，量化器期望512维
- **根因**: 不同子脑输出维度不一致
- **解决**: 为不同模态设计不同的量化策略，或统一维度
- **永久法则**: ✅ 多模态系统必须明确每个子脑的维度和量化方式

## E15: HTTP 协议解析缓冲区溢出
- **现象**: 超长HTTP请求导致缓冲区溢出
- **根因**: 未限制请求行/头的大小
- **解决**: 设置最大请求大小（如8192字节），超出返回413
- **永久法则**: ✅ 所有解析器必须有输入大小限制

## E16: ServerMetrics 非原子操作
- **现象**: 多线程环境下指标计数不准确
- **根因**: 普通 `u64` 在并发环境下会出现竞态
- **解决**: 使用 `std.atomic.Value(u64)` 并保证原子操作
- **永久法则**: ✅ 多线程共享的指标必须使用原子操作

## E17: SIGINT 信号处理竞态
- **现象**: 收到 SIGINT 后服务器未正确关闭
- **根因**: 信号处理函数中使用非异步信号安全的函数
- **解决**: 使用原子布尔标志 `running`，事件循环检查该标志
- **永久法则**: ✅ 信号处理应使用原子标志，避免在信号处理器中做复杂操作

## E18-E32: 待补充
> 以下踩坑记录待后续补充（实际开发中遇到的新问题）：
> - E18: [待补充]
> - E19: [待补充]
> ...
> - E32: [待补充]

---

## 总结：永久法则速查表

| 法则 | 内容 | 优先级 |
|------|------|--------|
| 第一诫 | 非测试文件禁止 `const std = @import("std")` | 🚨 最高 |
| 第二诫 | reactor.zig 无菌室，无std/storage导入 | 🚨 最高 |
| 第三诫 | protocol.zig 状态机内无 try/catch/orelse/? | 🚨 最高 |
| 第四诫 | server.zig 不导入底层模块 | 🚨 最高 |
| 原子操作 | Zig 0.16+ 使用 `.load()`/`.store()`/`.rmw()` | ✅ 高 |
| fd管理 | 所有fd必须有明确的关闭路径 | ✅ 高 |
| 内存管理 | Arena + defer deinit() 或明确 free | ✅ 高 |
| 外部依赖 | 必须处理不可用情况，优雅降级 | ✅ 高 |
