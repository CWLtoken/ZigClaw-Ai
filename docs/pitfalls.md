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

## E34: 延迟直方图 `buckets_initialized` 非原子化（2026-05-10 修复）

- **现象**: `buckets_initialized: bool` 在多线程环境下出现竞争读写，导致延迟直方图可能重复初始化或计数丢失
- **根因**: 初始代码使用普通 `bool` 而非 `atomic.Value(bool)`，`initLatencyBuckets()` 中对 `infer_latency_buckets` 数组的初始化可能与其他线程的 `observeInferLatency` 并发执行
- **解决**: 将 `buckets_initialized` 改为 `atomic.Value(bool)`，读加 `.load(.acquire)`，写加 `.store(true, .release)`（DRD-058/P1-1）
- **永久法则**: ✅ 任何跨线程共享的 bool/计数变量必须使用 `atomic.Value`，即使当前看似"只在一个地方写入"

## 总结：永久法则速查表

| 法则 | 内容 | 优先级 |
|------|------|--------|
| 第一诫 | 非测试文件禁止 `const std = @import("std")` | 🚨 最高 |
| 第二诫 | reactor.zig 无菌室，无std/storage导入 | 🚨 最高 |
| 第三诫 | protocol.zig 状态机内无 try/catch/orelse/? | 🚨 最高 |
| 第四诫 | server.zig 不导入底层模块 | 🚨 最高 |
|| 原子操作 | Zig 0.16+ 使用 `.load()`/`.store()`/`.rmw()` | ✅ 高 |
|| fd管理 | 所有fd必须有明确的关闭路径 | ✅ 高 |
|| 内存管理 | Arena + defer deinit() 或明确 free | ✅ 高 |

---

## E33: 延迟直方图 buckets_initialized 必须原子化（2026-05-10 新增）

- **现象**: `buckets_initialized: bool` 在多线程环境下出现竞争读写，延迟直方图可能重复初始化或计数丢失
- **根因**: 使用普通 `bool` 而非 `atomic.Value(bool)`，`initLatencyBuckets()` 与 `observeInferLatency` 并发执行
- **解决**: 将 `buckets_initialized` 改为 `atomic.Value(bool)`，读加 `.load(.acquire)`，写加 `.store(true, .release)`
- **永久法则**: ✅ 任何跨线程共享的 bool/计数变量必须使用 `atomic.Value`，即使当前看似"只在一个地方写入"

---

## E34: 运行时 C 依赖白名单（v6.5.0 新增）

> **来源**：DRD-061 架构师审计 — "无依赖0 需要明确 0 的边界"

### C 依赖白名单

项目运行时 C 依赖**仅限于**以下两项，禁止引入其他 C 库：

| 依赖 | 用途 | 引入方式 |
|------|------|----------|
| **libc** — `clock_gettime(CLOCK_MONOTONIC)` | 单调时间戳（请求上下文、延迟计算） | `context.zig` 通过 `@cImport(time.h)` |
| **io_uring 系统调用** | 异步文件/网络 I/O（io_uring_setup/openat/write/read） | `io_uring.zig` 直接 `std_os.syscall*` |

### image_feature.c / image_feature.h

这两个 C 文件出现在 `src/` 中，用途：**简单的图像特征提取占位**，目前只做零值填充，不依赖第三方图像库（libjpeg/libpng 等）。

**边界声明**：如未来接入 libjpeg/libpng/OpenCV，属于"引入第三方 C 依赖"，必须：
1. 在本文档 E33 中显式登记
2. 在 `docs/architecture.md` 多副本边界中更新外置依赖说明
3. 评估是否破坏"无第三方依赖"原则

---

## 第四诫：依赖引入评审流程（v6.5.0 新增）

> **来源**：DRD-061 架构师审计 — "军规中缺少对引入新依赖的正式评审机制"

### 🚨 第四诫（扩展）：依赖引入评审

凡引入**新运行时依赖**（C 库 / 外部服务 / Zig 包），必须执行以下评审：

1. **文档登记**：在本文档（pitfalls.md）的 E33 白名单中显式登记
2. **影响评估**：
   - 是否违反"零第三方依赖"原则？
   - 是否有纯 Zig 替代方案？
   - 对编译产物大小的影响（静态链接膨胀）？
   - 对启动时间的影响（动态链接 / 初始化开销）？
3. **架构评审**：在 `docs/architecture.md` 多副本边界中更新说明
4. **军规更新**：如依赖被接受，在本文档"永久法则"表中新增条目

### 当前已评估的候选依赖

| 候选 | 用途 | 评估结论 |
|------|------|----------|
| libjpeg / libpng | 真实图像特征提取 | ⚠️ 待 v4.0 评估 |
| Redis (hiredis) | 外置热度池 / 多副本共享 | ⚠️ 待 v4.0 评估 |
| gRPC | 跨节点推理编排 | ⚠️ 待 v5.0 评估 |
| Qdrant / Milvus | 外置向量检索 | ⚠️ 替代内置 IVF+PQ，待 v4.0 评估 |
| 外部依赖 | 必须处理不可用情况，优雅降级 | ✅ 高 |

---

## 军规适用范围

> **ZigClaw 编码军规不是装饰，是系统稳定性的核心保障。**
> 以下明确每条军规的适用层级、豁免条件和违反后果。

### 军规层级划分

| 层级 | 军规 | 适用范围 | 豁免条件 |
|------|------|----------|-----------|
| **P0 禁止** | 禁止 /// | 执行层（src/*.zig）+ 协议层 | **无豁免**。测试代码可用 ，但需显式处理错误 |
| **P0 禁止** | 禁止  整体导入（） | 全部  文件 | **无豁免**。必须精确导入（） |
| **P1 强制** | 精确导入原则：只导入用到的符号 | 全部  文件 | 测试辅助代码可放宽，但需注释说明 |
| **P1 推荐** | 显式错误传播（） | 执行层 + 协议层 | 测试代码可用 ，但需保证不隐藏错误 |
| **P2 建议** | 禁止 ，统一用  | 全部  文件 | 临时调试可用，但提交前必须清除 |

### 各层级的军规要求

#### 执行层（src/protocol.zig, src/reactor.zig, src/io_uring.zig）
- ✅ **必须**：零 /，全部显式 
- ✅ **必须**：精确导入，禁止 
- ✅ **必须**： 类型必须先用  判断，禁止 
- ✅ **必须**：错误类型用  或  显式枚举，禁止 

#### 存储层（src/storage.zig）
- ✅ **必须**：同上，零 /
- ⚠️ **建议**： 必须配合 ，且目标指针对齐必须已知

#### 协议层（src/router.zig, src/ibus.zig）
- ✅ **必须**：精确导入
- ⚠️ **建议**： 回调中的  必须做 null 检查

#### 测试层（src/tests.zig）
- ✅ **允许**：使用  和 （测试便利性）
- ⚠️ **建议**：测试中的  如果隐藏了真实错误，需用  显式处理

### 违反军规的后果

| 违反类型 | 后果 | 修复优先级 |
|----------|------|------------|
| / 出现在执行层 | 运行时错误被吞，系统静默失败 | **P0 立即修复** |
|  | 编译时间膨胀 + 命名空间污染 | **P0 立即修复** |
|  对  直接 unwrap | 运行时 panic，系统崩溃 | **P0 立即修复** |
|  | 违反显式错误传播原则，隐藏逻辑缺陷 | **P1 尽快修复** |
|  未清除 | 生产日志混乱，信息泄露 | **P2 下次提交修复** |

### 军规检查清单（提交前自查）

- [ ] 全仓库  确认执行层无 
- [ ] 全仓库  确认执行层无 
- [ ] 全仓库  确认无整体导入
- [ ] 全仓库  确认无不安全 
- [ ]  全绿（144/144）

> **架构师裁决**：军规不是可选项。违反军规的 PR 不予合并。
> 如果军规阻碍了你的实现，说明设计有问题，不是军规有问题。

