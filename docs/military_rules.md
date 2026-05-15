# ZigClaw-AI 军规文档

> **三诫六层，无菌室，零依赖。** 本文档定义 ZigClaw-AI 的核心开发军规，所有贡献者必须遵守。

---

## 第一诫：精确导入

**规则**：禁止在任何非测试文件中使用 `const std = @import("std")` 整包导入。

**原因**：整包导入隐式引入整个标准库，增加编译时间，无法追踪实际依赖，违反"显性直白"原则。

**正确做法**：
```zig
// ❌ 禁止
const std = @import("std");
const mem = std.mem;
const debug = std.debug;

// ✅ 正确：精确子导入
const mem = @import("std").mem;
const debug = @import("std").debug;
```

**适用范围**：所有 `src/*.zig` 文件（测试文件除外）

**检查方式**：
```bash
grep -rn 'const std = @import("std")' src/ --include='*.zig' | grep -v '_test.zig'
```

**当前状态**：✅ `src/` 核心文件已全部精确导入，`build.zig` 也已改为 `const Build = @import("std").Build`

---

## 第二诫：无菌室军规

**规则**：在无菌室文件（`reactor.zig`、`io_uring.zig`、`protocol.zig`）中，禁止使用 `try`、`catch`、`orelse` 进行隐式错误传播。所有错误处理必须是显式的 `if-else`。

**原因**：隐式错误传播掩盖控制流，使代码路径不透明。无菌室是系统最底层，必须对所有错误路径完全可见。

**无菌室文件清单**：
- `src/reactor.zig` — 执行层，io_uring 批量提交
- `src/io_uring.zig` — 执行层，原始 syscall 封装
- `src/protocol.zig` — 协议状态机

**正确做法**：
```zig
// ❌ 禁止：隐式 try
const fd = try Syscall.setup(1024, &params);

// ✅ 正确：显式 if-else
const fd = if (Syscall.setup(1024, &params)) |val| val else |err| return err;

// ❌ 禁止：隐式 catch
self.flush() catch |flush_err| { log.warn("..."); };

// ✅ 正确：显式 if-else
if (self.flush()) |_| {} else |flush_err| { log.warn("..."); }

// ❌ 禁止：空 catch（吞错误）
_ = fn() catch {};

// ✅ 正确：显式处理每一个错误
if (fn()) |val| { use(val); } else |err| { handle(err); }
```

**检查方式**：
```bash
grep -rn '\<try\>' src/reactor.zig src/io_uring.zig src/protocol.zig
grep -rn '\<catch\>' src/reactor.zig src/io_uring.zig src/protocol.zig
grep -rn '\<orelse\>' src/reactor.zig src/io_uring.zig src/protocol.zig
```

**当前状态**：✅ 全部无菌室文件已修复，零 `try`/`catch`/`orelse`

---

## 第三诫：零依赖

**规则**：核心运行时零第三方依赖。只允许 `std` + 自有模块。

**原因**：第三方依赖引入不可控的供应链风险、版本冲突和编译复杂性。ZigClaw-AI 的目标是成为可审计的系统级基础设施。

**允许的依赖**：
- `std`（Zig 标准库）
- 自有模块（`src/` 下的所有 `.zig` 文件）
- C 标准库（通过 `stb_image` 自包含 C 文件）

**禁止的依赖**：
- 任何外部 Zig 包（`zig fetch` 引入的）
- 任何系统级第三方库（libuv、openssl 等）
- 任何运行时动态链接库

**C 代码规则**：
- C 代码必须自包含在 `src/` 目录下
- 使用 `build.zig` 的 `addLibrary` + `addCSourceFile` 编译（禁止 `addSystemCommand`）
- 不允许 `#include` 系统级第三方头文件

**当前状态**：✅ 零第三方运行时依赖，C 库通过标准 Build API 构建

---

## 六层架构军规

**规则**：严格遵守六层静态分层，禁止跨层直接调用。

| 层 | 文件 | 职责 | 禁止 |
|----|------|------|------|
| 入口与服务层 | `main.zig`, `server.zig`, `http_server.zig` | HTTP 服务、推理客户端 | 直接调用执行层 |
| 编排层 | `orchestrator.zig`, `token.zig` | 多模态输入→Token→推理 | 直接调用存储层 |
| 路由层 | `route_table.zig`, `router.zig` | 向量检索、静态路由 | 直接调用执行层 |
| 执行层 | `reactor.zig`, `io_uring.zig` | io_uring 零拷贝 I/O | 直接调用 HTTP 层 |
| 存储层 | `storage.zig`, `heat_pool.zig` | 热池、SSD 持久化 | 直接调用编排层 |
| 观测层 | `metrics.zig`, `ibus.zig` | 原子指标、IBus | 修改业务状态 |

**层间通信**：通过 `interface.zig` 定义的编译期契约（VTable）进行。

---

## 性能军规

1. **零堆分配**：核心路径（执行层、存储层）禁止堆分配
2. **缓存行对齐**：所有高频争用原子变量必须使用 `AlignedAtomicU64`（64 字节对齐）
3. **批量提交**：io_uring SQE 必须批量提交，阈值通过编译期配置（默认 8）
4. **Comptime 路由**：路由表必须在编译期生成，禁止运行时路由查找
5. **连接池复用**：跨区 LLM 调用必须使用连接池，降低握手延迟

---

## 构建系统军规

1. **标准 Build API**：使用 `addLibrary` + `addCSourceFile`，禁止 `addSystemCommand`
2. **精确导入**：`build.zig` 使用 `const Build = @import("std").Build`，禁止整包导入
3. **依赖显性化**：`exe.linkLibrary(c_lib)` / `tests.linkLibrary(c_lib)` 必须显式声明
4. **编译期配置**：通过 `b.option` + `addOptions` 注入编译期常量（如 `BATCH_THRESHOLD`）

---

## 显性直白（设计哲学军规）

1. **契约显性化**：所有层间契约白纸黑字写在 `*_interface.zig` 里，编译器强制执行
2. **无隐藏依赖**：禁止魔法数字（Linux UAPI 常量除外，必须有注释说明）
3. **无过度封装**：禁止 VTable + `anyopaque` + `@ptrCast` 反向转换
4. **扁平分层**：每层一个目录，接口和实现同目录，不跨目录跳转
5. **零成本抽象**：用 `comptime` + `inline fn`，不增加运行时开销
6. **调试变量清理**：`pub var` 调试全局变量必须移除或改为条件编译

---

## 无依赖0（供应链安全军规）

1. **允许依赖**：`std`（Zig 标准库）、自有模块（`src/` 下所有 `.zig`）、C 标准库
2. **允许 C 依赖**：自包含 C 文件（如 `image_feature.c` + `stb_image.h`）
3. **禁止外部包**：任何 `zig fetch` 引入的外部 Zig 包
4. **禁止系统库**：libuv、openssl、libcurl、sqlite、redis 等系统级第三方库
5. **禁止 C 第三方头文件**：`#include <第三方头文件>`（标准 C 库除外）
6. **B 准入评审**：凡引入新 C 依赖，必须在 `docs/pitfalls.md` 中显式登记并评估

---

## v3.1 架构师审计修复记录

| 日期 | 级别 | 问题 | 文件 | 修复方式 |
|------|------|------|------|----------|
| 2026-05-11 | P1 | 调试全局变量 `pub var last_send_rc` | `io_uring.zig:493` | 移除变量及所有赋值 |
| 2026-05-11 | P1 | 全局数组 `pub var infer_latency_buckets = undefined` | `metrics.zig:62` | 改为 `[_]atomic.Value(u64){atomic.Value(u64).init(0)} ** NUM_BUCKETS` |
| 2026-05-11 | P2 | `catch unreachable` 在集成测试 | `integration_p35/48/49.zig` | 改为 `try` |
| 2026-05-11 | P2 | 栈缓冲区 `= undefined`（27处） | 多个文件 | 低优先级，可后续改为 `= [_]u8{0}` |

### 审计结论

- **P0 问题**：0 项
- **P1 问题**：2 项（已修复）
- **P2 问题**：3 项（1 项已修复，2 项低优先级记录）
- **五诫评分**：全部 ⭐⭐⭐⭐⭐
- **处决碑合规**：14 项反模式全部通过
- **物理层验证**：7 个结构体尺寸全部通过 comptime 守卫
- **判定**：✅ v3.1 达到"军规驱动系统级基础设施"标准

---

## 安全军规（架构师新增，v3.2）

| 编号 | 军规 | 说明 | 修复状态 |
|------|------|------|----------|
| **SEC-1** | **禁止硬编码凭证** | 所有凭证（Token、证书路径、密钥）必须从环境变量读取。`middleware.zig` 的 Token 从 `ZIGCLAW_AUTH_TOKEN` 读取，`main.zig` 的端口从 `ZIGCLAW_PORT` 读取。 | ✅ 已修复 |
| **SEC-2** | **禁止动态拼接命令/路径** | 禁止 `std.process.run` 执行动态拼接命令；禁止直接拼接用户输入构建文件路径。使用预定义命令数组 + 参数白名单。 | ✅ 已修复 |
| **SEC-3** | **TLS 必须使用 zig-tls 原生实现** | 禁止使用 OpenSSL/LibreSSL 等第三方 TLS 库。等待 Zig 0.17 迁移时集成 `zig-tls`。 | ⏳ 等待 0.17 |
| **SEC-4** | **必须实现 Rate Limiting** | 入口层必须具备自我保护能力，基于 `AlignedAtomicU64` 实现滑动窗口限流。 | ⏳ 待实现 |
| **SEC-5** | **必须限制请求体大小** | 显式校验 `Content-Length`，防止溢出攻击。 | ⏳ 待实现 |
| **SEC-6** | **必须添加安全响应头** | `X-Content-Type-Options: nosniff`、`X-Frame-Options: DENY`、`X-XSS-Protection: 1; mode=block`。 | ⏳ 待实现 |
| **SEC-7** | **错误信息不得泄露内部状态** | 客户端返回通用错误信息，详细错误仅记录内部日志。 | ⏳ 待实现 |

---

## 测试军规

1. **全绿基线**：所有测试必须保持全绿，新功能必须附带测试
2. **错误注入**：核心路径必须有错误注入测试（`test_integration/fault_injection.zig`）
3. **编译期守卫**：关键不变量必须通过 `comptime` 守卫锁死
4. **契约验证**：各层实现必须通过 `ContractVerifier` 编译期签名检查

---

## 版本历史

| 版本 | 日期 | 变更 |
|------|------|------|
| v1.0 | 2026-05-10 | 初版，三诫定义 |
| v1.1 | 2026-05-11 | 增加无菌室文件清单、性能军规、六层架构军规 |
| v1.2 | 2026-05-11 | 增加构建系统军规、测试军规、连接池复用、错误注入、编译期配置 |
