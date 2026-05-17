# ZigClaw-AI 执行层代码军规合规性审计报告

> 审计时间：2026-05-17
> 审计范围：reactor.zig / io_uring.zig / protocol.zig
> 审计标准：S-1/S-2/S-3/S-5/A-1/P-1/P-2/P-3/E-2/E-4/M-2

---

## 一、reactor.zig 审计（364行）

### reactor.zig 违规清单

| 行号 | 违规规则 | 违规内容 | 建议修复 |
|------|----------|----------|----------|
| 5 | **S-2 精确导入** | `const log = @import("std").log;` 使用了 `@import("std")` 整包导入语法 | 改为 `const log = @import("std").log;` → 虽然只用了 `.log`，但导入源仍是 `"std"` 整包。应确认 Zig 0.16 下是否可进一步精确；若 `log` 是独立模块则单独导入 |
| 66 | **S-1/S-3 显性直白/无菌室** | `self.flush() catch |err| { return err; };` — 使用 `catch` 关键字 | 改为 `if (self.flush()) |_| {} else |err| { return err; };` |
| 109 | **S-1/S-3 显性直白/无菌室** | `self.flush() catch |err| { return err; };` — 使用 `catch` 关键字 | 改为 `if (self.flush()) |_| {} else |err| { return err; };` |
| 152 | **S-1/S-3 显性直白/无菌室** | `self.flush() catch |err| { return err; };` — 使用 `catch` 关键字 | 改为 `if (self.flush()) |_| {} else |err| { return err; };` |
| 196 | **S-1/S-3 显性直白/无菌室** | `self.flush() catch |err| { return err; };` — 使用 `catch` 关键字 | 改为 `if (self.flush()) |_| {} else |err| { return err; };` |
| 239 | **S-1/S-3 显性直白/无菌室** | `self.flush() catch |err| { return err; };` — 使用 `catch` 关键字 | 改为 `if (self.flush()) |_| {} else |err| { return err; };` |
| 26 | **P-3 编译期批量阈值** | `BATCH_THRESHOLD` 通过 `@import("build_options")` 实现编译期常量，但使用了运行时 `if` 表达式而非 `comptime if`。在 Zig 0.16 中 `@hasDecl` 是 comptime，但整个 `if` 表达式是否完全在 comptime 求值存在歧义 | 改为 `comptime` 块内赋值，或使用 `comptime` 变量确保编译期确定 |
| 41-52 | **S-5 扁平低代码** | `flush` 函数仅12行，合规 | ✅ 合规 |
| 60-102 | **S-5 扁平低代码** | `prepare_recv` 函数 43 行（含注释），**超过40行限制** | 将 SQ 满溢保护逻辑提取为内联辅助逻辑或合并到公共序列中 |
| 105-144 | **S-5 扁平低代码** | `prepare_accept` 函数 40 行，处于边界 | ⚠️ 临界，建议精简注释 |
| 147-188 | **S-5 扁平低代码** | `prepare_send` 函数 42 行，**超过40行限制** | 同上，提取公共 SQE 填充模式 |
| 192-231 | **S-5 扁平低代码** | `prepare_write` 函数 40 行，处于边界 | ⚠️ 临界 |
| 235-274 | **S-5 扁平低代码** | `prepare_read` 函数 40 行，处于边界 | ⚠️ 临界 |
| 277-321 | **S-5 扁平低代码** | `poll` 函数 45 行，**超过40行限制** | 将 CQE 安全校验逻辑提取为独立函数 |
| 364 | **S-5 扁平低代码** | 文件总行数 364 行，未超过 400 行 | ✅ 合规 |
| 121 | **S-1 显性直白** | `if (addr) |a| @intFromPtr(a) else 0` — 使用 `orelse` 的 `if-else` 替代形式，这是显式写法 | ✅ 合规（这是 `if` 表达式而非 `orelse` 关键字） |
| 122 | **S-1 显性直白** | `if (addrlen) |al| ... else 0` — 同上 | ✅ 合规 |

### reactor.zig 合规亮点
- ✅ **P-5 延迟提交策略**：第 27-31 行有完整的军规注释保护 flush 调用位置
- ✅ **E-4 Reactor Flush 军规注释**：第 27-31 行和第 37-40 行均有军规注释
- ✅ **E-2 编译期布局断言**：第 323-362 行 comptime 块包含 IoComplete 布局校验、SQ_DEPTH 幂次守卫、原子操作语法检查
- ✅ **P-1 纯状态机并发**：无 async/await
- ✅ **P-2 显式资源清理**：无 errdefer
- ✅ **A-2 编译期契约**：comptime 块用于布局守卫

---

## 二、io_uring.zig 审计（504行）

### io_uring.zig 违规清单

| 行号 | 违规规则 | 违规内容 | 建议修复 |
|------|----------|----------|----------|
| **504** | **S-5 扁平低代码** | **文件总行数 504 行，超过 400 行限制** | 将网络相关函数（socket/bind/listen/connect/recv/send/accept）拆分为独立 `net.zig` 模块 |
| 227 | **S-2 精确导入** | `const linux = @import("std").os.linux;` — 虽然精确到了 `std.os.linux`，但基准文件明确禁止非测试文件出现 `const std = @import("std")` 形式。此处写法是 `@import("std").os.linux` 链式访问，非直接赋值给 `linux` 变量... 实际看代码：`const linux = @import("std").os.linux;` 这是精确导入的链式写法，`@import` 的参数仍是 `"std"` | 在 Zig 0.16 中无法进一步拆分 `@import("std").os.linux`，但按严格军规解释，这属于整包导入的变体。可考虑在 build 阶段做模块映射 |
| 123-215 | **S-5 扁平低代码** | `Ring.init` 函数 93 行，**严重超过40行限制** | 拆分为 `setup_fd`、`map_sq_ring`、`map_cq_ring`、`map_sqes`、`construct_ring` 等子函数 |
| 256-271 | **S-5 扁平低代码** | `Syscall.setup` 函数 16 行，合规 | ✅ |
| 272-292 | **S-5 扁平低代码** | `Syscall.map_ring` 函数 21 行，合规 | ✅ |
| 293-313 | **S-5 扁平低代码** | `Syscall.enter` 函数 21 行，合规 | ✅ |
| 333-346 | **S-5 扁平低代码** | `Syscall.openat` 函数 14 行，合规 | ✅ |
| 350-356 | **S-5 扁平低代码** | `Syscall.register` 函数 7 行，合规 | ✅ |
| 363-375 | **S-5 扁平低代码** | `Syscall.register_buffers` 函数 13 行，合规 | ✅ |
| 378-390 | **S-5 扁平低代码** | `Syscall.unregister_buffers` 函数 13 行，合规 | ✅ |
| 398-403 | **S-5 扁平低代码** | `Syscall.socket` 函数 6 行，合规 | ✅ |
| 406-409 | **S-5 扁平低代码** | `Syscall.bind` 函数 4 行，合规 | ✅ |
| 412-415 | **S-5 扁平低代码** | `Syscall.listen` 函数 4 行，合规 | ✅ |
| 418-421 | **S-5 扁平低代码** | `Syscall.getsockname` 函数 4 行，合规 | ✅ |
| 424-432 | **S-5 扁平低代码** | `Syscall.connect` 函数 9 行，合规 | ✅ |
| 435-444 | **S-5 扁平低代码** | `Syscall.recv` 函数 10 行，合规 | ✅ |
| 448-467 | **S-5 扁平低代码** | `Syscall.send` 函数 20 行，合规 | ✅ |
| 471-481 | **S-5 扁平低代码** | `Syscall.accept` 函数 11 行，合规 | ✅ |
| 493-497 | **S-5 扁平低代码** | `write` 函数 5 行，合规 | ✅ |
| 500-504 | **S-5 扁平低代码** | `read` 函数 5 行，合规 | ✅ |
| 19-21 | **A-1 六层静态隔离** | 顶层 `AF_INET`、`SOCK_STREAM`、`INADDR_LOOPBACK` 常量与第 393-395 行 `Syscall` 内部的同名常量**重复定义** | 删除顶层重复常量（19-21行）或删除 Syscall 内部的重复（393-395行） |
| 393-395 | **A-1 六层静态隔离** | `Syscall` 结构体内部再次定义 `AF_INET`、`SOCK_STREAM`、`INADDR_LOOPBACK`，与顶层 19-21 行重复 | 同上，消除重复 |
| 134 | **S-1 显性直白** | `if (Syscall.setup(1024, &params)) |val| val else |err| return err;` — 使用 `if-else` 显式错误处理 | ✅ 合规 |
| 147 | **S-1 显性直白** | `if (Syscall.map_ring(...)) |val| val else |err| { ... return err; }` — 显式 | ✅ 合规 |
| 157 | **S-1 显性直白** | 同上 `if-else` 模式 | ✅ 合规 |
| 176-181 | **S-1 显性直白** | `if (sqes_raw == @as(usize, @bitCast(@as(isize, -1))))` 显式错误判断 | ✅ 合规 |
| 5-16 | **M-2 幂次守卫** | `SQ_DEPTH`/`SQ_MASK` 有完整的 comptime 幂次守卫 | ✅ 合规 |
| 71-73 | **E-2 编译期布局断言** | `SqEntry` 有 `@sizeOf != 64` 断言 | ✅ 合规 |
| 82-84 | **E-2 编译期布局断言** | `CqEntry` 有 `@sizeOf != 16` 断言 | ✅ 合规 |
| 92-94 | **E-2 编译期布局断言** | `Iovec` 有 `@sizeOf != 16` 断言 | ✅ 合规 |

### io_uring.zig 合规亮点
- ✅ **P-1 纯状态机并发**：无 async/await
- ✅ **P-2 显式资源清理**：无 errdefer，`Ring.init` 中错误路径显式 munmap+close
- ✅ **S-1 显性直白**：所有错误处理均为 `if-else` 模式，无 try/catch/orelse
- ✅ **M-2 幂次守卫**：SQ_DEPTH/SQ_MASK 有完整 comptime 守卫
- ✅ **E-2 编译期布局断言**：SqEntry/CqEntry/Iovec 均有

---

## 三、protocol.zig 审计（134行）

### protocol.zig 违规清单

| 行号 | 违规规则 | 违规内容 | 建议修复 |
|------|----------|----------|----------|
| 3 | **S-2 精确导入** | `const mem = @import("std").mem;` — 精确到了 `std.mem`，但 `@import` 参数仍是 `"std"` 整包 | 同 reactor.zig 第5行问题。严格来说 `@import("std").mem` 是链式访问，但导入源仍是整包 `"std"` |
| 4 | **A-1 六层静态隔离** | `const core = @import("core.zig");` — protocol 属于协议层，core 属于核心层。需确认层级关系，若 protocol 在 core 之上则属于跨层直调 | 确认六层架构中 protocol 与 core 的层级关系，若跨层则需通过接口间接调用 |
| 5 | **A-1 六层静态隔离** | `const storage = @import("storage.zig");` — protocol 直接导入 storage，若 storage 是更低层则违反六层静态隔离 | 确认层级关系，跨层需通过抽象接口 |
| 6 | **A-1 六层静态隔离** | `const reactor = @import("reactor.zig");` — protocol 直接导入 reactor（执行层），若 protocol 在更高层则违反 | 确认层级关系 |
| 26 | **S-1/S-3 显性直白/无菌室** | `if (io_uring.Ring.init()) |ring| ring else |e| return e` — 这是 `if-else` 显式写法 | ✅ 合规（非 try/catch） |
| 61 | **S-1/S-3 显性直白/无菌室** | **`orelse` 关键字**：`self.body_pool.get_write_slice(self.active_stream_id) orelse { ... }` | 改为 `if (self.body_pool.get_write_slice(self.active_stream_id)) |write_slice| { ... } else { ... }` |
| 105 | **S-1/S-3 显性直白/无菌室** | **`orelse` 关键字**：`self.body_pool.get_write_slice(self.active_stream_id) orelse { ... }` | 改为 `if-else` 显式写法 |
| 51 | **S-1 显性直白** | `if (opt_header) |header| { ... }` — 使用 `if` 表达式处理 optional，这是显式写法（非 `orelse`） | ✅ 合规 |
| 59 | **S-1 显性直白** | `if (io.buf_ptr) |buf_ptr| { ... }` — 显式 `if` 解构 optional | ✅ 合规 |
| 103 | **S-1 显性直白** | `if (io.buf_ptr) |buf_ptr| { ... }` — 显式 | ✅ 合规 |
| 95 | **S-1 显性直白** | `if (opt_header) |header| { ... }` — 显式 | ✅ 合规 |
| 134 | **S-5 扁平低代码** | 文件总行数 134 行，未超过 400 行 | ✅ 合规 |
| 24-32 | **S-5 扁平低代码** | `init` 函数 9 行，合规 | ✅ |
| 34-126 | **S-5 扁平低代码** | `step` 函数 93 行，**严重超过40行限制** | 将 `HeaderRecv` 和 `BodyRecv` 分支的处理逻辑分别提取为 `handle_header_recv` 和 `handle_body_recv` 函数 |
| 128-133 | **S-5 扁平低代码** | `begin_receive` 函数 6 行，合规 | ✅ |
| 130 | **P-1 纯状态机并发** | `@atomicStore(u64, &self.active_stream_id, stream_id, .seq_cst)` — 使用原子操作而非锁 | ✅ 合规 |

### protocol.zig 合规亮点
- ✅ **P-1 纯状态机并发**：无 async/await，基于状态机流转
- ✅ **P-2 显式资源清理**：无 errdefer
- ✅ **S-5 扁平低代码**：文件总行数 134 行，合规

---

## 四、总结

### 违规统计

| 规则 | reactor.zig | io_uring.zig | protocol.zig | 合计 |
|------|:-----------:|:-------------:|:------------:|:----:|
| **S-1 显性直白** | 5 (catch) | 0 | 2 (orelse) | **7** |
| **S-2 精确导入** | 1 | 1 | 1 | **3** |
| **S-3 无菌室** | 5 (catch) | 0 | 2 (orelse) | **7** |
| **S-5 扁平低代码** | 3函数超限 | 1文件超限+1函数超限 | 1函数超限 | **6** |
| **A-1 六层隔离** | 0 | 2 (重复常量) | 3 (跨层导入) | **5** |
| **P-3 编译期阈值** | 1 (歧义) | 0 | 0 | **1** |

### 文件合规评级

| 文件 | 评级 | 说明 |
|------|------|------|
| **reactor.zig** | ⚠️ **基本合规，需修复** | 5处 `catch` 关键字违反 S-1/S-3；3个函数超40行；BATCH_THRESHOLD 的 comptime 确定性有歧义 |
| **io_uring.zig** | ⚠️ **基本合规，需修复** | **文件504行超400行红线**（最严重）；`Ring.init` 93行严重超标；顶层与 Syscall 内常量重复 |
| **protocol.zig** | ⚠️ **基本合规，需修复** | 2处 `orelse` 关键字违反 S-1/S-3；`step` 函数93行严重超标；3个跨层导入需确认 |

### 最突出的问题（按严重程度排序）

1. 🔴 **io_uring.zig 文件 504 行超 400 行红线**（S-5 硬违规）— 需立即拆分
2. 🔴 **`Ring.init` 93 行 / `step` 93 行严重超 40 行限制**（S-5 硬违规）— 需拆分子函数
3. 🟡 **7 处 `catch`/`orelse` 关键字**（S-1/S-3 违规）— reactor.zig 5处 `catch`，protocol.zig 2处 `orelse`，需全部改为 `if-else`
4. 🟡 **protocol.zig 跨层导入 core/storage/reactor**（A-1 风险）— 需确认六层架构中 protocol 的层级位置
5. 🟡 **io_uring.zig 常量重复定义**（A-1）— 顶层与 Syscall 内 AF_INET/SOCK_STREAM/INADDR_LOOPBACK 重复
6. 🟢 **3 处精确导入写法**（S-2 轻微）— `@import("std").xxx` 链式写法，严格说导入源仍是整包

### 最终结论

**三个文件均未达到完全军规合规。** 没有一个文件可以评为"军规级完成"。最严重的问题是 **io_uring.zig 文件行数超标** 和 **多个函数严重超长**，其次是 **`catch`/`orelse` 关键字的系统性使用** 违反了 S-1/S-3 核心军规。修复优先级：先拆文件/函数（S-5），再消除 catch/orelse（S-1/S-3），最后确认跨层依赖（A-1）。
