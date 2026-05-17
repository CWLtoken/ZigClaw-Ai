# ZigClaw-AI 执行层技术文档

> **版本**: V2.5  
> **架构**: 分形计算 + io_uring + 无锁原子操作  
> **语言**: Zig 0.16  
> **更新日期**: 2026-05-18

---

## 一、架构总览

### 1.1 执行层组件图

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ZigClaw-AI 执行层                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐          │
│  │   Router     │    │  Scheduler   │    │   Worker     │          │
│  │  router.zig  │    │ scheduler.zig│    │  worker.zig  │          │
│  │              │    │              │    │              │          │
│  │ 双向翻译:    │    │ 任务队列     │    │ 5状态生命周期│          │
│  │ LLM→TaskStr  │    │ 分裂策略     │    │ 乱序扫描     │          │
│  │ TaskStr→token│    │ 自动回收     │    │ L1缓存预取   │          │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘          │
│         │                   │                   │                   │
│         ▼                   ▼                   ▼                   │
│  ┌─────────────────────────────────────────────────────────┐       │
│  │                    TaskString (256位状态串)               │       │
│  │                   task_string.zig                        │       │
│  │                                                         │       │
│  │  bits[0]: 槽位 0-63   (CPU agent)                       │       │
│  │  bits[1]: 槽位 64-127 (GPU agent)                       │       │
│  │  bits[2]: 槽位 128-191(FPGA agent)                      │       │
│  │  bits[3]: 槽位 192-255(ASIC agent)                      │       │
│  └─────────────────────────────────────────────────────────┘       │
│         │                   │                   │                   │
│         ▼                   ▼                   ▼                   │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐          │
│  │  Protocol    │    │   Reactor    │    │  IO_Uring    │          │
│  │ protocol.zig │    │  reactor.zig │    │ io_uring.zig │          │
│  │              │    │              │    │              │          │
│  │ 状态机:      │    │ io_uring封装 │    │ 底层syscall  │          │
│  │ Idle→Header  │    │ 延迟提交     │    │ SQE/CQE管理  │          │
│  │ →Body→Done   │    │ 批量flush    │    │ 内存映射     │          │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘          │
│         │                   │                   │                   │
│         └───────────────────┼───────────────────┘                   │
│                             ▼                                       │
│  ┌─────────────────────────────────────────────────────────┐       │
│  │                    Storage Layer                         │       │
│  │                   storage.zig                            │       │
│  │                                                         │       │
│  │  StreamWindow:  TokenStreamHeader 环形缓冲区            │       │
│  │  BodyBufferPool: 1024×4KB 槽位 + CAS原子分配            │       │
│  └─────────────────────────────────────────────────────────┘       │
│                             │                                       │
│                             ▼                                       │
│  ┌─────────────────────────────────────────────────────────┐       │
│  │                    Network Layer                         │       │
│  │                     net.zig                              │       │
│  │                                                         │       │
│  │  纯 linux syscall 封装，零依赖                           │       │
│  │  socket/bind/listen/accept/recv/send/close              │       │
│  └─────────────────────────────────────────────────────────┘       │
│                                                                     │
│  ┌──────────────┐    ┌──────────────┐                              │
│  │ Cache Layer  │    │  Metrics     │                              │
│  │cache_layer   │    │  metrics.zig │                              │
│  │              │    │              │                              │
│  │ L1/L2对称缓存│    │ 无锁原子指标 │                              │
│  │ 预取+回写    │    │ 缓存行对齐   │                              │
│  └──────────────┘    └──────────────┘                              │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────┐       │
│  │                    HTTP Server                           │       │
│  │                  http_server.zig                         │       │
│  │                                                         │       │
│  │  io_uring 驱动 HTTP 服务器                              │       │
│  │  Rate Limiter (CAS 无锁实现)                            │       │
│  │  请求路由 → Protocol → Reactor                          │       │
│  └─────────────────────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.2 数据流

```
LLM 输出 ──→ Router.routeTask() ──→ TaskString.set(slot)
                                        │
                                        ▼
                              Worker 乱序扫描 TaskString
                                        │
                                        ▼
                              Worker.execute() → Protocol.step()
                                        │
                                        ▼
                              Reactor.poll() → io_uring CQE
                                        │
                                        ▼
                              Storage: StreamWindow + BodyBufferPool
                                        │
                                        ▼
                              Router.routeFeedback() → token 串 → LLM 读取
```

---

## 二、核心组件详解

### 2.1 TaskString — 256位状态任务串

**文件**: `task_string.zig`

TaskString 是执行层的核心数据结构，用 256 位（4×u64）表示 256 个任务槽位的活跃状态。

```zig
pub const TaskString = struct {
    bits: [4]u64,  // 256 bits = 4 × 64 bits
    // bits[0]: 槽位 0-63   → CPU agent
    // bits[1]: 槽位 64-127 → GPU agent
    // bits[2]: 槽位 128-191 → FPGA agent
    // bits[3]: 槽位 192-255 → ASIC agent
};
```

**关键操作**:
- `set(slot)` — 原子 OR 设置位（`@atomicRmw(.Or)`）
- `clear(slot)` — 原子 AND 清除位（`@atomicRmw(.And)`）
- `isSet(slot)` — 非原子读取（仅用于单线程扫描）

**分形思想**: 256 位状态码将连续任务离散化，每位代表一个任务槽，实现"无限细分到状态"的分形计算模型。

**槽位范围 → 异构类型映射**:
| 槽位范围 | Agent 类型 | 任务难度 |
|---------|-----------|---------|
| 0-63    | CPU       | 最低    |
| 64-127  | GPU       | 中等    |
| 128-191 | FPGA      | 较高    |
| 192-255 | ASIC      | 最高    |

### 2.2 Router — 双向翻译器

**文件**: `router.zig`

Router 是 LLM 与执行层之间的桥梁，负责双向翻译：

**正向翻译** (`routeTask`): LLM 输出 → TaskString
- 接收 LLM 输出的任务描述
- 使用 FNV-1a 哈希提取任务特征码（仅用于追踪）
- **顺序扫描**分配空闲槽位（SEC-2 修复：不使用 LLM 输出计算槽位，防止操纵）
- 返回分配的槽位号

**反向翻译** (`routeFeedback`): TaskString → token 串
- 扫描 TaskString 中所有活跃槽位
- 将每个活跃槽位编码为 2 字节 token（槽位号 + 状态）
- 输出 token 串供 LLM 读取

**反向翻译（失败）** (`routeFailures`): 仅扫描失败槽位
- 用于失败反馈到 LLM

**Token 编码**:
```zig
pub const Token = packed struct {
    slot: u8,       // 槽位号 (0-255)
    state: SlotState, // 当前状态
};
// 编码: [slot: u8, state: u8] = 2 bytes
```

### 2.3 Reactor — io_uring 封装

**文件**: `reactor.zig`

Reactor 是对 Linux io_uring 的零抽象封装，提供延迟提交策略。

**核心设计**:
- **延迟提交**: SQE 不立即提交到内核，而是累积到 `BATCH_THRESHOLD`（默认 8）后批量提交
- **批量 flush**: 进入 `poll()` 前必须 flush 所有挂起的 SQE
- **显式错误处理**: 所有错误通过 `if-else` 显式处理，禁止 `try/catch`

**SQE 准备函数**:
- `prepare_recv()` — 提交 RECV 请求
- `prepare_accept()` — 提交 ACCEPT 请求
- `prepare_send()` — 提交 SEND 请求
- `prepare_write()` — 提交 WRITE 请求（异步文件写入）
- `prepare_read()` — 提交 READ 请求（异步文件读取）

**CQE 消费** (`poll()`):
1. flush 所有挂起 SQE
2. 检查 CQ 是否有新事件
3. 安全校验: user_data 非零且指针对齐
4. 返回 `Event.IoComplete` 或 `Event.Idle`

**编译期守卫**:
- `IoComplete` 布局检查（必须 24 字节）
- `SQ_DEPTH` 必须是 2 的幂
- 原子操作语法检查

### 2.4 Protocol — DMA 协议状态机

**文件**: `protocol.zig`

Protocol 实现基于 io_uring 的 DMA 数据传输协议。

**状态机**:
```
Idle → HeaderRecv → BodyRecv → BodyDone
                  ↘ Error
```

**状态转换**:
1. `Idle`: 等待 `begin_receive()` 触发
2. `HeaderRecv`: 接收 TokenStreamHeader（8 字节 stream_id + 4 字节长度）
3. `BodyRecv`: 循环接收数据体，直到剩余长度为 0
4. `BodyDone`: 数据接收完成
5. `Error`: 错误状态（使用不透明错误码，不泄露内部状态）

**错误码映射** (SEC-7 修复):
| 错误码 | 含义（内部） | 对外描述 |
|-------|------------|---------|
| 1     | DMA 流不匹配 | 通用错误 |
| 2     | 无效头部长度 | 通用错误 |
| 3     | 长度下溢 | 通用错误 |
| 4     | 体缓冲区满 | 通用错误 |
| 5     | 体流不匹配 | 通用错误 |
| 6     | I/O 错误 | 通用错误 |

### 2.5 Worker — 生命周期管理

**文件**: `worker.zig`

Worker 是执行层的基本执行单元，维护 5 状态生命周期。

**状态机**:
```
idle → Acquire → execute → report → idle
        ↓           ↓
    (分裂)      (完成)
        ↓           ↓
    Acquire     idle
```

**乱序扫描**:
- Worker 从 `scan_offset` 开始扫描 TaskString
- 不区分优先级，扫描顺序即执行顺序
- 成功：静默清除任务位
- 失败：清除任务位 + 记录失败原因

**L1 缓存预取**:
- 每个 Worker 维护 4 槽位的 L1 缓存
- 从 L2（TaskString）预取任务到 L1
- L1 命中直接执行，未命中从 L2 取

### 2.6 Scheduler — 集中式调度器

**文件**: `scheduler.zig`

Scheduler 负责任务队列管理和 Worker 分配。

**调度策略**:
- 任务发布：入队 → 分配 idle worker → Acquire → execute
- 分裂策略：`execute_count` 决定目标数量，系统占用 ≥70% 停止
- 自动回收：无任务时 idle → error，保留最少 4 个

**任务状态**:
```
pending → assigned → executing → completed
                            ↘ failed
```

### 2.7 Storage — 存储池

**文件**: `storage.zig`

**StreamWindow**: TokenStreamHeader 环形缓冲区
- 固定大小数组存储 header
- 支持 push/access/release 操作
- 线性扫描查找 stream_id

**BodyBufferPool**: 1024×4KB 内存热池
- 每个槽位 4096 字节缓冲区
- CAS 原子分配槽位（防止 stream_id 冲突）
- 位图管理：32 个 u32 管理 1024 个槽位

### 2.8 IO_Uring — 底层 syscall 封装

**文件**: `io_uring.zig`

对 Linux io_uring 的零依赖封装。

**核心结构**:
- `Ring`: io_uring 实例（fd + mmap 映射）
- `SqeEntry`: 严格映射 Linux `struct io_uring_sqe`（64 字节）
- `IOOp`: 操作码枚举（NOP/ReadV/WriteV/Accept/Read/Write/Recv/Send）

**内存映射**:
- SQ 环：`mmap(addr, SQ_DEPTH * sizeof(SqEntry))`
- CQ 环：`mmap(addr, CQ_DEPTH * sizeof(CqEntry))`
- SQE 数组：`mmap(addr, SQ_DEPTH * sizeof(SqEntry))`

**Syscall 封装**:
- `enter()`: `io_uring_enter()` 系统调用
- `setup()`: `io_uring_setup()` 系统调用
- `mmap()`: 内存映射辅助函数

### 2.9 Net — 网络 syscall 封装

**文件**: `net.zig`

纯 linux syscall 网络封装，与 io_uring 解耦。

**功能**:
- `socket()` / `bind()` / `listen()` / `accept()`
- `connect()` / `recv()` / `send()` / `close()`
- `getsockname()` / `htons()`

**设计原则**:
- 直接封装 linux syscall，无中间抽象层
- 所有错误处理显式 if-else
- 零堆分配

### 2.10 Cache Layer — 对称缓存

**文件**: `cache_layer.zig`

**L1 缓存** (Worker 本地):
- 4 槽位小型缓存
- 从 L2 预取任务槽位
- 缓存行对齐（64 字节）

**L2 缓存** (全局共享):
- TaskString 驻留
- 所有 Worker 共享

**对称缓存流水线**:
```
L2 (TaskString) → 预取 → L1 (Worker 本地) → 执行 → 回写 L2
```

### 2.11 Metrics — 无锁原子指标

**文件**: `metrics.zig`

**缓存行对齐原子变量**:
```zig
pub const AlignedAtomicU64 = struct {
    value: atomic.Value(u64) align(64),
    _pad: [64 - @sizeOf(atomic.Value(u64))]u8 = undefined,
};
```

每个原子变量独占 64 字节缓存行，消除多核/多线程下的伪共享。

**CAS 操作** (Zig 0.16 适配):
```zig
pub fn compareExchangeWeak(self: *AlignedAtomicU64, expected: u64, new_value: u64,
    comptime success_order: builtin.AtomicOrder, comptime failure_order: builtin.AtomicOrder) ?u64 {
    const result = @cmpxchgWeak(u64, &self.value.raw, expected, new_value, success_order, failure_order);
    ...
}
```

### 2.12 HTTP Server — io_uring 驱动 HTTP 服务器

**文件**: `http_server.zig`

基于 io_uring 的高性能 HTTP 服务器。

**特性**:
- io_uring 驱动异步 I/O
- Rate Limiter（CAS 无锁实现）
- 请求路由 → Protocol → Reactor
- 安全响应头

---

## 三、技术规范

### 3.1 编译期契约

| 规则 | 说明 | 检查方式 |
|-----|------|---------|
| SQ_DEPTH 必须为 2 的幂 | 用于位掩码取模 | `@compileError` |
| SQ_MASK = SQ_DEPTH - 1 | 位掩码正确性 | `@compileError` |
| IoComplete 必须 24 字节 | 内存布局完整性 | `@compileError` |
| SQ_DEPTH 必须为 comptime_int | 编译期常量 | `@compileError` |

### 3.2 原子操作规范

| 操作 | 使用场景 | 内存序 |
|-----|---------|-------|
| TaskString.set() | 标记任务活跃 | `.monotonic` |
| TaskString.clear() | 清除任务位 | `.monotonic` |
| BodyBufferPool.alloc_slot() | CAS 分配槽位 | `.acq_rel` |
| Reactor.flush() | 提交 SQE 到内核 | N/A (syscall) |
| Rate Limiter | CAS 更新时间戳 | `.acq_rel` / `.acquire` |

### 3.3 安全规范

| 规则 | 说明 | 修复状态 |
|-----|------|---------|
| SEC-1 | 无硬编码凭证 | ✅ 已通过 |
| SEC-2 | 无动态命令拼接 | ✅ 已修复（Router 槽位分配） |
| SEC-4 | Rate Limiter | ✅ 已有（CAS 无锁） |
| SEC-5 | 请求体大小限制 | ✅ 已有（MAX_BODY_SIZE=8KB） |
| SEC-6 | 安全响应头 | ✅ 已有 |
| SEC-7 | 错误信息不泄露 | ✅ 已修复（Protocol/Reactor） |

### 3.4 性能规范

| 指标 | 值 | 说明 |
|-----|---|------|
| SQ_DEPTH | 1024 | SQ 环深度 |
| BATCH_THRESHOLD | 8 | 延迟提交阈值 |
| BodyBufferPool 槽位数 | 1024 | 每个 4KB |
| L1 缓存槽位数 | 4 | 每个 Worker |
| 缓存行大小 | 64 字节 | x86_64 / ARM64 |
| MAX_BODY_SIZE | 8192 字节 | HTTP 请求体限制 |

### 3.5 军规合规性

| 军规 | 说明 | 状态 |
|-----|------|------|
| S-1 显式直白 | 状态转换显式可见 | ✅ |
| S-2 精确导入 | 链式精确导入 | ✅ |
| S-3 无菌室 | 显式 if-else 错误处理 | ✅ |
| S-5 扁平平代码 | 函数 ≤40 行 | ⚠️ 部分待拆分 |
| 零依赖 | 仅使用 linux syscall | ✅ |
| 编译期路由 | build_options 配置 | ✅ |

---

## 四、执行层数据流详解

### 4.1 任务提交流程

```
1. LLM 输出任务描述
2. Router.routeTask(llm_output)
   ├─ 提取任务特征码（FNV-1a 哈希，仅用于追踪）
   ├─ 顺序扫描 TaskString 找空闲槽位
   ├─ TaskString.set(slot) — 原子设置位
   └─ 返回 slot 号
3. Worker 乱序扫描发现活跃槽位
4. Worker.execute() → Protocol.step()
5. Protocol 通过 Reactor 发起 io_uring 操作
6. 数据写入 BodyBufferPool
7. 完成后 TaskString.clear(slot)
```

### 4.2 反馈流程

```
1. Router.routeFeedback(token_buf)
   ├─ 扫描 TaskString 所有活跃槽位
   ├─ 编码为 Token（槽位号 + 状态）
   └─ 写入 token_buf
2. LLM 读取 token 串
3. 根据状态决定下一步
```

### 4.3 错误处理流程

```
1. Protocol 检测到错误
   ├─ 设置 State.Error{ .code = N }（不透明错误码）
   └─ 不泄露内部状态细节
2. Reactor 检测到错误
   ├─ log.warn("通用描述")（不暴露内核错误名）
   └─ 继续执行（不 panic）
3. Worker 检测到错误
   ├─ TaskString.clear(slot)
   └─ 记录失败原因
```

---

## 五、Zig 0.16 适配说明

### 5.1 显式类型标注

Zig 0.16 要求显式类型标注，禁止隐式类型推断。执行层已全面修复：

- 所有 `@as(usize, @intCast(...))` 改为显式 `u32` 类型
- 所有 `var` 声明添加显式类型标注
- 所有整数常量添加显式类型后缀

### 5.2 原子操作

Zig 0.16 中 `atomic.Value` 使用 `@cmpxchgWeak` 实现 CAS：

```zig
// 正确方式
const result = @cmpxchgWeak(u64, &self.value.raw, expected, new_value, success_order, failure_order);

// 错误方式（Zig 0.16 不支持）
self.value.compareAndSwap(expected, new_value, success_order, failure_order);
```

### 5.3 错误捕获

Zig 0.16 要求未使用的错误捕获变量使用 `_`：

```zig
// 正确方式
if (self.flush()) |_|} else |_|{ ... }

// 错误方式（unused capture）
if (self.flush()) |_|} else |err|{ ... }  // 如果 err 未使用
```

---

## 六、测试策略

### 6.1 单元测试

每个 `.zig` 文件包含 `test` 块：

| 文件 | 测试内容 |
|-----|---------|
| task_string.zig | set/clear/isSet 基本操作 |
| router.zig | Token 编解码、routeTask、routeFeedback |
| cache_layer.zig | L1 缓存预取、对称缓存一致性 |
| net.zig | SockAddrIn 大小验证 |
| scheduler.zig | 任务队列操作、Worker 分配 |

### 6.2 集成测试

```bash
zig build test  # 运行所有测试
```

### 6.3 编译期测试

通过 `comptime` 块在编译期验证：
- 内存布局正确性
- 常量约束（SQ_DEPTH 为 2 的幂）
- 原子操作语法

---

## 七、性能优化记录

### 7.1 已完成优化

1. **缓存行对齐**: 所有原子变量独占 64 字节缓存行，消除伪共享
2. **CAS 无锁 Rate Limiter**: 替代 load-check-store 模式
3. **延迟提交**: SQE 批量提交减少 syscall 次数
4. **零堆分配**: 仅使用栈上和静态内存
5. **死导入清理**: 移除未使用的 heap/StringHashMap/debug 导入

### 7.2 待优化项

1. **S-5 扁平平代码**: http_server.zig `run()` 函数 183 行，需拆分
2. **io_uring.zig `Ring.init()`**: 93 行，需按阶段拆分
3. **io_uring.zig `Syscall` 结构体**: 183 行，需按功能分组

---

## 八、安全修复记录

### 8.1 P0 修复（2026-05-18）

| 问题 | 文件 | 修复方式 |
|-----|------|---------|
| 错误信息泄露内部状态 | protocol.zig | Error.reason → Error.code（不透明错误码） |
| 日志暴露内核错误名 | reactor.zig | `@errorName(flush_err)` → 通用描述 |
| 日志暴露指针地址 | reactor.zig | `{x}` 指针输出 → 通用描述 |
| LLM 输出操纵槽位 | router.zig | `task_code % 256` → 顺序扫描分配 |

### 8.2 编译验证

```bash
$ zig build
Build Summary: 4/4 steps succeeded

$ zig build test
All tests pass
```

---

*文档生成时间: 2026-05-18*  
*维护者: ZigClaw-AI 执行层团队*  
*审核状态: 待审核*
