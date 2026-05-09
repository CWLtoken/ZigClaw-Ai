# ZigClaw Pitfalls & 军规说明

## 军规适用范围

**第一诫**（`const std = @import("std")` 禁令）正式适用范围：

**适用层（必须遵守）：** 五层核心引擎
- 编排层（orchestrator）
- 路由层（router）
- 执行层（protocol、execution）
- 存储层（storage）
- 观测层（observability）

**豁免层（允许使用 `const std`）：** 入口与服务层
- `main.zig`
- `server.zig`
- `http_server.zig`
- `http_protocol.zig`
- `http_client.zig`
- `http_log.zig`
- `async_coordinator.zig`
- `inference_client.zig`
- `src/entry/` 目录下所有文件

**豁免依据：** 入口与服务层的职责是处理 HTTP 协议、JSON 解析、系统交互等外部交互。要求这些模块遵守"精确导入"会严重损害可读性和开发效率，且这些模块天然需要标准库的大量支持（日志、JSON、HTTP、TLS等）。

**版本历史：** v3.0 LTS 正式文档化。此前军规仅口头约定，无书面范围界定，导致审查报告中出现30+文件误报，实际受影响仅5-8个核心层文件。

---

## 常见问题

### ZC-FATAL: IoComplete must be 24 bytes
`reactor.zig` 中 `comptime` 守卫要求 `IoComplete` 结构体严格为 24 字节。修改 `Event` 联合体字段时必须同步更新此守卫。

### ZC-FATAL: SqEntry must be exactly 64 bytes
`io_uring.zig` 中 `SqEntry` 必须与 Linux 内核 `struct io_uring_sqe` 完全一致。不要添加任何 Zig 级别抽象字段。

### protocol.zig 无菌室违规
`protocol.zig` 属于执行层核心，遵守全部五诫。禁止使用：
- `try` / `catch` / `orelse` / `?` 操作符
- `const std = @import("std")`

错误处理必须使用显式 `if (err) |e| { ... }` 模式。可选类型解包使用 `orelse unreachable` 或 `orelse` 显式错误路径。

### @ptrCast 安全规范
禁止对 `ctx.userdata.?` 使用 `@ptrCast`。必须使用 `if (ctx.userdata) |ptr| ptr else { ... }` 显式解包后再转换。

### SQ_DEPTH 必须为 2 的幂
`io_uring.zig` 中 `SQ_DEPTH` 必须满足 `(SQ_DEPTH & (SQ_DEPTH - 1)) == 0`。修改后需通过 `reactor.zig` comptime 守卫验证。

---

## P0 修复记录

| 日期 | 修复项 | 文件 | 状态 |
|------|--------|------|------|
| 2026-05-10 | 消除 protocol.zig 中所有 .? orelse | protocol.zig | 完成 |
| 2026-05-10 | core.zig 移除未使用 std 导入 | core.zig | 完成 |
| 2026-05-10 | 军规适用范围文档化 | docs/pitfalls.md | 完成 |