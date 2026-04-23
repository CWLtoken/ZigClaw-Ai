# ZigClaw v2.4 | 2026-04-22 编译清单

> 目标环境：6.18.18-gentoo-microsoft-standard-WSL2（自编译内核）
> Zig 版本：0.16.0
> 编译命令：`zig build test`

---

## 一、代码改动与依据

### 1.1 reactor.zig — 2 处改动（🔴 红牌裁决后修订）

#### ~~改动 A：补加 `std` 导入~~ — 🔴 已否决回退

```diff
- const std = @import("std");  ← 已删除
  const io_uring = @import("io_uring.zig");
```

**裁决**：架构师红牌否决。reactor.zig 是无菌室，禁止非测试源文件顶部 `const std`。已回退。

#### 改动 B：守卫 1 + 守卫 4b — 🔴 已否决回退，替换为下标硬取

**原改动（已废弃）**：守卫 1 用 `std.mem.eql` 字符串遍历匹配 `IoComplete`；守卫 4b 用 `std.mem.eql` 字符串遍历匹配 `sq_head`/`sq_tail`。

**裁决**：架构师红牌否决。字符串比对是最高开销解决最简单问题的方式，且引入 std 依赖污染无菌室。

**替换方案（已生效）**：

守卫 1 — Event union 下标硬取：
```zig
const IoComplete = @typeInfo(Event).@"union".fields[0].type;
```

守卫 4b — Ring struct 下标硬取：
```zig
const ring_fields = @typeInfo(io_uring.Ring).@"struct".fields;
if (ring_fields[0].type != u32 or ring_fields[1].type != u32) {
    @compileError("ZC-FATAL: sq_head/sq_tail must be u32");
}
```

**依据**：`io_uring.Ring` 字段顺序由我们自己定义——`sq_head` 是第 0 字段，`sq_tail` 是第 1 字段。Event union 中 `IoComplete` 是第 0 字段。下标硬取零 std 依赖，纯正泥泞守卫。

---

### 1.2 integration_p3.zig — 3 处改动

#### 改动 C：补加模块级 body_pool

```diff
  const protocol = @import("protocol.zig");
+ var test_body_pool = storage.BodyBufferPool.init();
```

#### 改动 D：Protocol.init 补齐 body_pool 参数

```diff
- var proto = protocol.Protocol.init(&window);
+ var proto = protocol.Protocol.init(&window, &test_body_pool);
```

**依据**：`Protocol.init` 签名为 `init(window: *storage.StreamWindow, body_pool: *storage.BodyBufferPool)`，需要 2 个参数。P3 原来只传了 1 个，缺 `body_pool`。当前能编译过是因为 P3 测试路径不触发 `BodyRecv` 分支的 `body_pool` 解引用，但一旦触发就是 segfault。

#### 改动 E：5 处 sq_tail 写入统一为原子操作

```diff
- proto.reactor.ring.sq_tail += 1;
+ @atomicStore(u32, &proto.reactor.ring.sq_tail, proto.reactor.ring.sq_tail + 1, .release);
```

**依据**：P4/P5 的生产者线程都用 `@atomicStore` 写 `sq_tail`，P3 用普通赋值。虽然 P3 是单线程不影响正确性，但 reactor.zig 的 `poll()` 用 `@atomicLoad(.acquire)` 读 `sq_tail`，混用原子读+非原子写是 C11 内存模型中的 data race（即使单线程也不符合 Zig 的原子契约）。统一为 `@atomicStore(.release)` 确保 acquire-release 配对。

---

### 1.3 integration_p4.zig — 2 处改动

#### 改动 F：补加模块级 body_pool

```diff
  const protocol = @import("protocol.zig");
+ var test_body_pool = storage.BodyBufferPool.init();
```

#### 改动 G：Protocol.init 补齐 body_pool 参数

```diff
- var proto = protocol.Protocol.init(&window);
+ var proto = protocol.Protocol.init(&window, &test_body_pool);
```

**依据**：同改动 D。P4 跨线程测试的 BodyRecv 分支一定会触发 `body_pool` 解引用，缺少此参数必然 segfault。

---

### 1.4 integration_p5.zig — 1 处改动

#### 改动 H：@ptrCast 显式目标类型

```diff
- .buf_ptr = @ptrCast(&fake_body_chunk1),
+ .buf_ptr = @as(?*anyopaque, @ptrCast(&fake_body_chunk1)),

- .buf_ptr = @ptrCast(&fake_body_chunk2),
+ .buf_ptr = @as(?*anyopaque, @ptrCast(&fake_body_chunk2)),
```

**依据**：Zig 0.16 的 `@ptrCast` 需要显式目标类型参数 `@ptrCast(DestType, value)`。单参数形式 `@ptrCast(value)` 让编译器推导目标类型，在某些上下文中可能二义。显式写 `@as(?*anyopaque, @ptrCast(...))` 消除歧义，也和 `buf_ptr` 字段的 `?*anyopaque` 类型声明完全一致。

---

### 1.5 tests.zig — 1 处改动（🟡 黄牌：暂时容忍，阶段1结束前迁移）

#### 改动 I：comptime 引用确保 test 块可见

```diff
  const p3 = @import("integration_p3.zig");
  const p4 = @import("integration_p4.zig");
  const p5 = @import("integration_p5.zig");
+
+ comptime {
+     _ = p3;
+     _ = p4;
+     _ = p5;
+ }
```

**依据**：Zig 死代码消除（Lazy Field Analysis）——`const p3 = @import(...)` 只是声明了命名空间引用，如果 `p3` 从未被使用，编译器不会对 `integration_p3.zig` 做语义分析，其中的 `test` 块被直接丢弃。`comptime { _ = p3; }` 强制编译器引用该模块，触发完整语义分析，test 块才能被发现。这是 Zig 0.16 懒字段分析的副作用，不是 bug。

---

### 1.6 未改动的文件

| 文件 | 理由 |
|------|------|
| `build.zig` | 已符合 0.16 范式 |
| `core.zig` | 纯 `[13]u8` 容器，无 0.16 兼容问题 |
| `storage.zig` | 纯存储池，无 0.16 兼容问题 |
| `io_uring.zig` | 泥淖骨架即将替换，枚举值(0/1)与内核(22/23)不符是已知设计偏差 |
| `protocol.zig` | `@subWithOverflow` 已是 0.16 新语法，无问题 |

---

### 1.6 已知但未处理的风险

| # | 风险 | 说明 | 处理策略 |
|---|------|------|----------|
| R1 | `std.Thread.Semaphore` → `std.Io.Semaphore` | Zig 0.16 发布说明标记为硬迁移，但当前代码编译能过，可能是弃用别名仍保留 | 若编译报错则改 `const Semaphore = std.Io.Semaphore` |
| R2 | P5 的 `Semaphore{ .permits = 0 }` | P4 用 `Semaphore{}` 零值初始化，P5 用 `.permits = 0` 显式初始化，`std.Io.Semaphore` 的结构可能不同 | 若编译报错则统一为 P4 的 `Semaphore{}` 写法 |
| R3 | reactor.zig 守卫 3（零开销包装器） | liburing 绑定后 `Ring` 不再是值类型，`@sizeOf(Reactor) == @sizeOf(Ring)` 将失败 | 本次不改，liburing 绑定时再炸毁 |
| R4 | `All 0 tests passed` | Zig 0.16 懒字段分析：`const p3 = @import(...)` 不引用则 test 块被丢弃 | 已修复：`comptime { _ = p3; }` 强制引用 |

---

## 三、第二轮编译错误修复（2026-04-23）

> 触发：WSL2 实际编译暴露 7 个错误

### 3.1 错误与修复对照

| # | 错误信息 | 根因 | 修复 | 文件 |
|---|----------|------|------|------|
| E1 | `enum 'builtin.AtomicOrder' has no member named 'seqcst'` | Zig 0.16 重命名 `.seqcst` → `.seq_cst` | `.seqcst` → `.seq_cst` | protocol.zig:112 |
| E2 | `root source file struct 'Thread' has no member named 'Semaphore'` | `std.Thread.Semaphore` 已移除，迁移到 `std.Io.Semaphore` | `Thread.Semaphore` → `Io.Semaphore` | integration_p4.zig:7, integration_p5.zig:7 |
| E3 | `coercion from enum to union must initialize 'Error' field` | Zig 0.16 不允许用枚举标签 `.Error` 直接强转为带 payload 的 tagged union | `expectEqual(State.Error, s1)` → `expect(s1 == .Error)` | integration_p3.zig:30,54 |
| E4 | `expected type 'type', found '@typeInfo(reactor.Event).@"union".tag_type.?'` | `Event.IoComplete` 在 Zig 0.16 中无法直接作为类型使用，因为 `Event` 是 tagged union，`.IoComplete` 是枚举标签而非独立类型 | 用 `@typeInfo(Event).Union.fields` 按名字查找字段类型 | reactor.zig:48 |
| E5 | `expected type '[*]u8', found '*u8'` | Zig 0.16 禁止单指针 `*u8` 隐式强转为多指针 `[*]u8` | 加 `@as([*]u8, @ptrCast(...))` | storage.zig:50 |

### 3.2 功能性改动说明（Semaphore 迁移）

**Semaphore 迁移是功能性改动，不只是语法修复**：

- 旧 `std.Thread.Semaphore`：`wait()` / `post()` 无参数
- 新 `std.Io.Semaphore`：`wait(io: Io)` / `post(io: Io)` 需要 `Io` 实例

**改动内容**：
1. TestContext 新增 `io: Io` 字段
2. 初始化时 `testing.io` 传入
3. 消费者线程（主测试线程）：`wait(io) catch {}` / `post(io)`
4. 生产者线程：`waitUncancelable(io)` / `post(io)`
5. Semaphore 初始化从 `Semaphore{}` / `Semaphore{ .permits = 0 }` 统一为 `.{}`（默认 permits=0）

**设计决策**：
- 生产者线程用 `waitUncancelable` 而非 `wait`，因为生产者线程不处理取消
- 消费者线程用 `wait(io) catch {}` 忽略取消错误，保持测试简单性
- `std.testing.io` 是测试框架提供的 Io 实例，在非测试线程中使用是安全的（Io 是值类型，可跨线程复制）

### 3.3 第三轮编译错误修复（@typeInfo 字段名 + P3 测试逻辑）

| # | 错误 | 根因 | 修复 | 文件 |
|---|------|------|------|------|
| E6 | `no field named 'Union' in union 'builtin.Type'` | Zig 0.16 中 `@typeInfo` 返回的 `builtin.Type` 字段名使用转义语法：`.Union` → `.@"union"`，`.Struct` → `.@"struct"` | `.Union` → `.@"union"`，`.Struct` → `.@"struct"` | reactor.zig:48,56,111 |
| E7 | `expected type '[]const u8', found '@TypeOf(null)'` | `expectFmt` 第一个参数不接受 null | `expectFmt(null, ...)` → `expect(mem.indexOf(...))` | integration_p4.zig:70 |
| E8 | P3 测试 `expected .BodyDone, found .Error` | P3 最后一次重置后直接塞 buf_len=60 的 entry，但 HeaderRecv 阶段校验 result!=13 → Error | 拆成两步：先塞 buf_len=13 通过 HeaderRecv，再塞 buf_len=60 通过 BodyRecv → BodyDone | integration_p3.zig:59-67 |

### 3.4 最终结果

```
1/3 integration_p3.test.Integration: Protocol State Machine Lifecycle & Defenses...OK
2/3 integration_p4.test.Phase4: SPSC 跨线程原子指针有效性验证 - 严格时序Happy Path...OK
3/3 integration_p5.test.Phase5: 真实物理内存搬运 - 血管已打通，血肉注入...OK
All 3 tests passed.
```

**3/3 绿灯，编译验证通过。**

---

## 二、阶段 0 裁决报告（2026-04-23）

### 2.1 裁决结果

| 标记 | 改动 | 裁决 | 处理 |
|------|------|------|------|
| 🔴 红牌 | reactor.zig 改动 A（`const std` 导入） | **否决** — 无菌室禁止非测试 std | 已回退删除 |
| 🔴 红牌 | reactor.zig 改动 B（`std.mem.eql` 字符串比对） | **否决** — 高开销解决低问题 | 已替换为下标硬取 |
| 🟡 黄牌 | tests.zig 改动 I（`comptime { _ = p3; }`） | **暂容忍** — 编译器行为妥协，技术债 | 阶段1结束前迁移到 build.zig root_module |
| 🟢 绿牌 | protocol.zig `.seq_cst` 修复 | 通过 | — |
| 🟢 绿牌 | storage.zig `@as([*]u8, @ptrCast(...))` | 通过 | — |
| 🟢 绿牌 | integration_p*.zig Semaphore 迁移 | 通过 | 测试代码不受无菌室约束 |
| 🟢 绿牌 | integration_p*.zig 补齐 body_pool 参数 | 通过 | 之前挖的坑，填上了 |

### 2.2 黄金基线验证（v2.4-p5-frozen）

```
1/3 integration_p3.test.Integration: Protocol State Machine Lifecycle & Defenses...OK
2/3 integration_p4.test.Phase4: SPSC 跨线程原子指针有效性验证 - 严格时序Happy Path...OK
3/3 integration_p5.test.Phase5: 真实物理内存搬运 - 血管已打通，血肉注入...OK
All 3 tests passed.
```

**基线状态**：`rm -rf zig-cache && zig build test` → 退出码 0，3/3 绿灯。

---

## 三、编译错误报告（已填写）

> 以下为三轮编译的完整错误记录。

### 3.1 第一轮（语法审查，预判修复）

无 WSL 编译，纯代码审查发现 6 处问题并主动修复。

### 3.2 第二轮（WSL 实际编译，7 个错误）

| # | 错误信息 | 根因 | 修复 | 文件 |
|---|----------|------|------|------|
| E1 | `enum 'builtin.AtomicOrder' has no member named 'seqcst'` | Zig 0.16 重命名 `.seqcst` → `.seq_cst` | `.seqcst` → `.seq_cst` | protocol.zig:112 |
| E2 | `root source file struct 'Thread' has no member named 'Semaphore'` | `std.Thread.Semaphore` 已移除，迁移到 `std.Io.Semaphore` | `Thread.Semaphore` → `Io.Semaphore` | integration_p4.zig:7, integration_p5.zig:7 |
| E3 | `coercion from enum to union must initialize 'Error' field` | Zig 0.16 不允许用枚举标签 `.Error` 直接强转为带 payload 的 tagged union | `expectEqual(State.Error, s1)` → `expect(s1 == .Error)` | integration_p3.zig:30,54 |
| E4 | `expected type 'type', found '@typeInfo(reactor.Event).@"union".tag_type.?'` | `Event.IoComplete` 在 Zig 0.16 中无法直接作为类型使用 | 用 `@typeInfo(Event).@"union".fields` 按名字查找字段类型 | reactor.zig:48 |
| E5 | `expected type '[*]u8', found '*u8'` | Zig 0.16 禁止单指针隐式强转为多指针 | 加 `@as([*]u8, @ptrCast(...))` | storage.zig:50 |

### 3.3 第三轮（2 个编译错误 + 1 个测试逻辑错误）

| # | 错误 | 根因 | 修复 | 文件 |
|---|------|------|------|------|
| E6 | `no field named 'Union' in union 'builtin.Type'` | Zig 0.16 中 `@typeInfo` 返回的 `builtin.Type` 字段名使用转义语法 | `.Union` → `.@"union"`，`.Struct` → `.@"struct"` | reactor.zig:48,56,111 |
| E7 | `expected type '[]const u8', found '@TypeOf(null)'` | `expectFmt` 第一个参数不接受 null | `expectFmt(null, ...)` → `expect(mem.indexOf(...))` | integration_p4.zig:70 |
| E8 | P3 测试 `expected .BodyDone, found .Error` | P3 最后一次重置后直接塞 buf_len=60，HeaderRecv 校验 result!=13 → Error | 拆成两步：先 buf_len=13 通过 HeaderRecv，再 buf_len=60 通过 BodyRecv → BodyDone | integration_p3.zig:59-67 |

### 3.4 裁决后回退修复（第四轮）

| # | 改动 | 根因 | 修复 |
|---|------|------|------|
| R-A | reactor.zig 删除 `const std` | 架构师红牌：无菌室禁止 std | 已删除 |
| R-B | 守卫1：`std.mem.eql` 字符串遍历 → 下标 `[0]` | 架构师红牌：零 std 依赖 | `@typeInfo(Event).@"union".fields[0].type` |
| R-C | 守卫4b：`std.mem.eql` 字符串遍历 → 下标 `[0]`/`[1]` | 架构师红牌：下标硬取 | `ring_fields[0].type != u32 or ring_fields[1].type != u32` |

### 3.5 最终基线结果

```
1/3 integration_p3.test.Integration: Protocol State Machine Lifecycle & Defenses...OK
2/3 integration_p4.test.Phase4: SPSC 跨线程原子指针有效性验证 - 严格时序Happy Path...OK
3/3 integration_p5.test.Phase5: 真实物理内存搬运 - 血管已打通，血肉注入...OK
All 3 tests passed.
```

---

## 四、阶段 1 开发记录（2026-04-23）

### 4.1 DRD-001 / ZC-1-02：io_uring_setup 系统调用降维（初版）

**操作**：在 `io_uring.zig` 末尾追加 `SetupParams` + `Syscall.setup()`，使用 `std.os.linux.io_uring_setup` 封装。

**结果**：编译通过（3/3 绿灯），但 `Syscall.setup` 未被调用，编译器懒分析跳过函数体。

**⚠️ 预警**：`std.os.linux.io_uring_setup` 在 Zig 0.16 标准库中可能不存在。当前绿灯是假象——一旦调用，链接期或编译期可能崩溃。

### 4.2 DRD-001 修正 / ZC-1-02+04 合并：纯 syscall 降维层（终极修正版）

**操作**：删除初版，替换为纯 `syscall3`/`syscall6` 降维层：
- `Syscall.setup(entries, params)` — 直接用 `syscall3(.io_uring_setup, ...)` 敲击 425 号门牌
- `Syscall.map_ring(fd, offset, size)` — 直接用 `syscall6(.mmap, ...)` 映射 Ring 内存

**第五轮编译错误**：

| # | 错误 | 根因 | 修复 | 文件 |
|---|------|------|------|------|
| E9 | `expected 1 argument, found 2` on `@bitCast(i32, @truncate(u32, rc))` | Zig 0.16 `@bitCast` 移除双参数形式，只接受单参数（类型推导） | 拆为两步：`const rc_trunc: u32 = @truncate(rc); const fd: i32 = @bitCast(rc_trunc);` | io_uring.zig:73 |
| E10 | `expected 1 argument, found 2` on `@bitCast(u32, fd)` | 同上 | `@as(usize, @intCast(@as(u32, @bitCast(fd))))` — i32→u32 bitCast推导 + intCast→usize | io_uring.zig:91 |

**关键 Zig 0.16 踩坑**：`@bitCast` 在 0.16 中从双参数 `@bitCast(DestType, value)` 变为单参数 `@bitCast(value)`，目标类型从变量声明推导。此变更未在 breaking_changes.md 中记录，属于新发现。

### 4.3 最终验证

```
1/3 integration_p3.test.Integration: Protocol State Machine Lifecycle & Defenses...OK
2/3 integration_p4.test.Phase4: SPSC 跨线程原子指针有效性验证 - 严格时序Happy Path...OK
3/3 integration_p5.test.Phase5: 真实物理内存搬运 - 血管已打通，血肉注入...OK
All 3 tests passed.
```

**状态**：3/3 绿灯，ZC-1-02/04 终极修正版编译通过。`Syscall.setup` 和 `Syscall.map_ring` 已定义但未被调用，等待架构师下发 DRD-002 将管道插入 `Ring.init()`。

### 4.4 DRD-003 / ZC-1-05：Ring 结构体真实化

**操作**：删除旧 `Ring`（静态数组体 `[1024]SubmissionEntry`），替换为指针型 `Ring`（fd + 内核映射指针）。

**预期**：守卫 3（零开销包装器）必然引爆。

**第六轮编译**：6 个错误，守卫 4b 抢先引爆（sq_head/sq_tail 从 u32 变成 *u32），守卫 3 未轮到。

### 4.5 DRD-004 / ZC-1-06：级联修复 — 全面适配指针化 Ring

**操作**：4 个文件同时修复

| 文件 | 改动 |
|------|------|
| io_uring.zig | `@ptrFromInt` → `[*]u8` 基址 + 偏移指针算术；sqes_ptr 显式类型；`sq_ring_entries` → `sq_entries`（字段名修正） |
| reactor.zig | `&self.ring.sq_tail` → `self.ring.sq_tail`（去掉 &）；删除守卫 3（零开销包装器）；删除守卫 4b（sq_head/sq_tail 类型）；删除守卫 5（Ring.init comptime 实例化——现在包含运行时 syscall） |
| integration_p3.zig | `sq_tail & io_uring.SQ_MASK` → `sq_tail.* & io_uring.SQ_MASK`（解引用）；`&proto.reactor.ring.sq_tail` → `proto.reactor.ring.sq_tail`（去掉 &） |
| integration_p4.zig | `&ctx.proto.reactor.ring.sq_tail` → `ctx.proto.reactor.ring.sq_tail`（去掉 &） |
| integration_p5.zig | 同 P4 |

**错误递减**：6 → 5 → 2

**架构师指令外额外修复**：
- `params.sq_ring_entries` → `params.sq_entries`（SetupParams 字段名引用错误）
- `@atomicStore(u32, &self.ring.sq_head, ...)` → `@atomicStore(u32, self.ring.sq_head, ...)`（sq_head 也是指针，需要去 &）
- 守卫 5 删除：`Ring.init()` 现在包含运行时 syscall（`Syscall.setup` + `map_ring`），不能在 comptime 块中调用

**剩余 2 个错误（等待架构师指令）**：

| # | 错误 | 说明 |
|---|------|------|
| E11 | `@ptrCast increases pointer alignment`：`[*]u8`(align 1) → `*u32`(align 4) | 需要加 `@alignCast` 断言对齐，但超出 DRD-004 指令范围 |
| E12 | `struct 'os.linux.MAP__struct_14988' has no member named 'SHARED'` | Zig 0.16 标准库的 `MAP` packed struct 字段名可能从大写改为小写或其他命名，需查 Zig 0.16 源码确认 |

### 4.6 DRD-005 / ZC-1-07：终极缝合 — 对齐断言与内核魔数替换

**操作**：
1. 6 处 `@ptrCast(sq_base/cq_base + offset)` 前包裹 `@alignCast`
2. `sqes_ptr` 的 `@ptrCast` 也包裹 `@alignCast`
3. `std_os.MAP.SHARED | std_os.MAP.POPULATE` → `0x01 | 0x20000`（Linux x86_64 UAPI 魔数）
4. `std_os.PROT.READ | std_os.PROT.WRITE` → `0x1 | 0x2`（Linux x86_64 UAPI 魔数）
5. `std_os.MAP_FAILED` → `@as(usize, @bitCast(@as(isize, -1)))`（Linux x86_64 UAPI 魔数）

**编译结果**：0 错误，编译通过。

**运行时结果**：3/3 crash

```
thread panic: incorrect alignment
src/io_uring.zig:55:35: const cq_head_ptr: *u32 = @ptrCast(@alignCast(cq_base + params.cq_off.head));
```

**分析**：`@alignCast` 在运行时检查指针对齐。`cq_base` 是 CQ ring 的 mmap 基址（页对齐），但 `cq_base + params.cq_off.head` 的偏移量可能不是 4 字节对齐。这是因为 CQ ring 的 `cq_off.head` 偏移量由内核在 `io_uring_setup` 返回时填入，其值取决于内核版本和结构体布局。

**Zig 0.16 标准库踩坑**：
- `std.os.linux.MAP` 从具名字段改为 packed struct，字段名不再是大写常量（如 `SHARED`/`POPULATE`）
- `std.os.linux.PROT` 同理（字段名不再是 `READ`/`WRITE`）
- `std.os.linux.MAP_FAILED` 不再作为常量暴露
- 解决方案：绕过标准库，直接用 Linux UAPI 原始魔数

### 4.7 DRD-006 / ZC-1-08：页对齐修复 — mmap 偏移量取整

**死因分析**：`@alignCast` 在 `cq_head_ptr` 处触发 `incorrect alignment` panic。根因：`sq_ring_size`（4144）不是 PAGE_SIZE（4096）的整数倍，mmap 偏移量被内核静默向下取整到最近的页边界，导致 CQ ring 基址错位。

**操作**：将 `sq_ring_size` 和 `cq_ring_size` 的原始计算结果向上取整到 4096 字节边界：
```zig
const sq_ring_size_raw: usize = params.sq_off.array + (params.sq_entries * @sizeOf(u32));
const cq_ring_size_raw: usize = params.cq_off.cqes + (params.cq_entries * 16);
const sqes_size: usize = params.sq_entries * 64;
const PAGE: usize = 4096;
const sq_ring_size: usize = (sq_ring_size_raw + PAGE - 1) & ~(PAGE - 1);
const cq_ring_size: usize = (cq_ring_size_raw + PAGE - 1) & ~(PAGE - 1);
```

**编译结果**：0 错误（不变）。

**运行时结果**：**All 3 tests passed.** — Ring 真实化完美通过。

```
Build Summary: 3/3 steps succeeded; 3/3 tests passed
test success
+- run test 3 pass (3 total) 16ms MaxRSS:19M
```

**状态**：v2.4-p6-frozen。io_uring_setup 系统调用 + mmap 页对齐 Ring 真实化全部通过。内核 fd 已拿到，内存已映射，指针已对齐。
