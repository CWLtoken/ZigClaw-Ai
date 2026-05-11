# CI 代码规范检查清单 (P0-2)

> 本文档定义 CI 流水线中必须通过的代码规范检查项，集成到 `build.zig` 或 GitHub Actions 中。

## 1. 禁止整包导入

**规则**：禁止使用 `const std = @import("std");`

**原因**：整包导入会隐式引入整个标准库，增加编译时间，且无法追踪实际依赖。

**检查方式**：
```bash
grep -rn 'const std\s*=\s*@import("std")' src/ --include='*.zig' | grep -v '_test.zig'
```

**修复方式**：替换为精确子导入，例如：
```zig
// ❌ 禁止
const std = @import("std");
const mem = std.mem;

// ✅ 正确
const mem = @import("std").mem;
```

## 2. 禁止在非测试文件中使用 testing

**规则**：`std.testing` 仅允许在 `_test.zig` 文件中导入。

**检查方式**：
```bash
grep -rn '@import("std").testing' src/ --include='*.zig' | grep -v '_test.zig'
```

## 3. 原子变量禁止直接读写

**规则**：所有 `atomic.Value<T>` 必须使用 `.load()` / `.store()` / `.fetchAdd()` 等原子方法访问。

**检查方式**：
```bash
# 检查是否有非原子方式的读写（模式匹配）
grep -rn 'buckets_initialized[^_]' src/ --include='*.zig' | grep -v 'if\|while\|//\|\.load\|\.store'
```

## 4. @deprecated 标注规范

**规则**：废弃的 API 必须标注 `@deprecated` 并附带迁移说明。

**检查方式**：
```bash
# 检查所有 deprecated 是否都有描述信息
grep -rn '@deprecated("' src/ --include='*.zig' | grep '!deprecate.*""'
```

## 5. 禁止未使用的导入

**规则**：所有 `const/var` 导入的模块必须在文件中被使用。

**集成建议**：使用 `zls` (Zig Language Server) 的 `unused import` 诊断。

## 6. 编译期检查

**规则**：以下编译期守卫必须始终通过：
- `comptime` 尺寸对齐检查（`AlignedAtomicU64`）
- 无未使用的 `pub` 导出

## 7. 无菌室军规：禁止隐式错误传播

**规则**：在无菌室文件（`reactor.zig`、`io_uring.zig`、`protocol.zig`）中，禁止使用 `try`、`catch`、`orelse` 进行隐式错误传播。必须使用显式 `if-else` 错误处理。

**原因**：隐式错误传播掩盖控制流，使代码路径不透明。无菌室军规要求所有错误处理必须是显式的 `if (expr) |val| { ... } else |err| { ... }`。

**检查方式**：
```bash
# 检查无菌室文件中的 try/catch/orelse
grep -rn '\<try\>' src/reactor.zig src/io_uring.zig src/protocol.zig
grep -rn '\<catch\>' src/reactor.zig src/io_uring.zig src/protocol.zig
grep -rn '\<orelse\>' src/reactor.zig src/io_uring.zig src/protocol.zig
```

**修复方式**：
```zig
// ❌ 禁止（隐式 try）
const fd = try Syscall.setup(1024, &params);

// ✅ 正确（显式 if-else）
const fd = if (Syscall.setup(1024, &params)) |val| val else |err| return err;

// ❌ 禁止（隐式 catch）
self.flush() catch |flush_err| { log.warn("..."); };

// ✅ 正确（显式 if-else）
if (self.flush()) |_| {} else |flush_err| { log.warn("..."); }
```

**适用范围**：`reactor.zig`、`io_uring.zig`、`protocol.zig`（执行层无菌室）

## 8. 构建系统军规：禁止 addSystemCommand

**规则**：`build.zig` 中禁止使用 `b.addSystemCommand` 构建 C 库。必须使用 `b.addLibrary` + `b.addCSourceFile`。

**原因**：`addSystemCommand` 启动子进程编译，无法统一控制 target/optimize，破坏交叉编译支持。

**检查方式**：
```bash
grep -rn 'addSystemCommand' build.zig
```

**修复方式**：
```zig
// ❌ 禁止
const c_src = b.addSystemCommand(&.{ "zig", "build-exe", "src/image_feature.c", "--library", "c" });

// ✅ 正确
const c_mod = b.createModule(.{ .root_source_file = null, .target = target, .optimize = optimize });
c_mod.addCSourceFile(.{ .file = b.path("src/image_feature.c"), .flags = &.{"-std=c11"} });
c_mod.linkSystemLibrary("c", .{});
const c_lib = b.addLibrary(.{ .name = "image_feature", .root_module = c_mod });
```

**适用范围**：`build.zig`

## 9. 错误注入测试覆盖

**规则**：核心路径（执行层、协议层）必须有对应的错误注入测试，覆盖以下场景：
- io_uring 初始化失败
- EAGAIN（资源暂时不可用）
- 磁盘满（ENOSPC）
- 连接中断（recv 返回 0 或 ECONNRESET）

**测试位置**：`src/test_integration/fault_injection.zig`

**编译期守卫**：以下不变量必须通过 `comptime` 守卫锁死：
- `SyscallError` 包含至少 5 个错误变体
- `Ring.init` 返回 error union
- `Ring.deinit` 返回 void
- `AlignedAtomicU64` 64 字节对齐
- `ConnSlot` 不超过 64 字节

**检查方式**：
```bash
zig build test  # 全绿即通过
```

## 集成到 CI

在 `build.zig` 中添加：

```zig
pub fn ci_checks(b: *std.Build) void {
    const check_step = b.step("ci-check", "Run CI code quality checks");

    // 检查1: 禁止整包导入
    const grep_std = b.addSystemCommand(&.{
        "grep", "-rn", @"const std\s*=",
        "src/", "--include=*.zig",
    });
    check_step.dependOn(&grep_std.step);
}
```

## 违规记录

| 日期 | 文件 | 违规项 | 修复者 |
|------|------|--------|--------|
| 2026-05-10 | 47 个 integration test | 整包导入 std | Hermes Agent |
| 2026-05-10 | metrics.zig | buckets_initialized 非原子读写 | Hermes Agent |
| 2026-05-11 | reactor.zig / io_uring.zig | 隐式 try/catch 错误传播 | Hermes Agent |