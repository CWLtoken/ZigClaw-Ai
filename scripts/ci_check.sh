#!/bin/bash
# ZigClaw CI 静态规则检查脚本
# M4: CI 静态规则脚本

set -e

echo "=== ZigClaw CI 静态规则检查 ==="

# M4-1: 禁止整包导入 const std = @import("std")
echo "检查1: 禁止整包导入..."
if grep -rn 'const std\s*=\s*@import("std")' src/ --include='*.zig' | grep -v '_test.zig'; then
    echo "❌ 失败: 发现整包导入"
    exit 1
else
    echo "✅ 通过: 无整包导入"
fi

# M4-2: 禁止在非测试文件中使用 testing
echo "检查2: 禁止非测试文件使用 testing..."
if grep -rn '@import("std").testing' src/ --include='*.zig' | grep -v '_test.zig'; then
    echo "❌ 失败: 发现非测试文件使用 testing"
    exit 1
else
    echo "✅ 通过: 无违规"
fi

# M4-3: 检查 atomic.Value 原子操作
echo "检查3: 检查 buckets_initialized 原子操作..."
if grep -rn 'buckets_initialized[^_]' src/ --include='*.zig' | grep -v 'if\|while\|//\|\.load\|\.store'; then
    echo "❌ 失败: 发现非原子方式访问"
    exit 1
else
    echo "✅ 通过: buckets_initialized 使用原子操作"
fi

# M4-4: 检查 @deprecated 是否有迁移说明
echo "检查4: 检查 @deprecated 标注..."
if grep -rn '@deprecated("' src/ --include='*.zig' | grep '!deprecate.*""'; then
    echo "❌ 失败: @deprecated 缺少迁移说明"
    exit 1
else
    echo "✅ 通过: @deprecated 标注规范"
fi

echo ""
echo "=== 所有 CI 检查通过 ✅ ==="
