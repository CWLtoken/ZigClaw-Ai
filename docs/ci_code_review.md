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