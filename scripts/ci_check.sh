#!/bin/bash
# ZigClaw CI 静态规则检查脚本
# M4: CI 静态规则脚本

set -e

echo "=== ZigClaw CI 静态规则检查 ==="

# M4-1: 禁止整包导入 const std = @import("std")（测试文件豁免）
echo "检查1: 禁止整包导入..."
# 扫描非测试文件（排除 integration_p*_test.zig 和 tests.zig）
VIOLATIONS=$(grep -rn 'const std\s*=\s*@import("std")' src/ --include='*.zig' | grep -v '_test\.zig' | grep -v 'tests\.zig' | grep -v 'integration_p' | grep -v '//' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "❌ 失败: 发现整包导入:"
    echo "$VIOLATIONS"
    exit 1
else
    echo "✅ 通过: 无整包导入"
fi

# M4-2: 禁止在非测试文件中导入 testing 但不包含 test 块
# 说明：Zig 允许任何文件内联 test 块，这是标准模式
# 本检查只拦截"导入 testing 却没有任何 test 块"的浪费行为
echo "检查2: 非测试文件 testing 导入合理性..."
VIOLATIONS=""
while IFS= read -r file; do
    [ -z "$file" ] && continue
    if ! grep -q 'test "' "$file" 2>/dev/null; then
        VIOLATIONS="$VIOLATIONS\n  $file (导入 testing 但无 test 块)"
    fi
done < <(grep -rln '@import("std").testing' src/ --include='*.zig' | grep -v 'integration_p' | grep -v '_test\.zig' | grep -v 'tests\.zig' || true)
if [ -n "$VIOLATIONS" ]; then
    echo "❌ 失败: 以下文件导入 testing 但无 test 块:"
    echo -e "$VIOLATIONS"
    exit 1
else
    echo "✅ 通过: 所有 testing 导入均有对应 test 块"
fi

# M4-3: 检查 buckets_initialized 必须通过 atomic.Value 访问（.load/.store）
echo "检查3: buckets_initialized 原子操作..."
# 先确认变量声明是 atomic.Value(bool)
if ! grep -rn 'buckets_initialized.*atomic.Value(bool)' src/ --include='*.zig' | grep -v '//' > /dev/null 2>&1; then
    echo "❌ 失败: buckets_initialized 未声明为 atomic.Value(bool)"
    exit 1
fi
# 确认没有直接读写（= 赋值而非 .store）
if grep -rn 'buckets_initialized\s*=' src/ --include='*.zig' | grep -v '//' | grep -v '\.store' | grep -v 'atomic.Value' > /dev/null 2>&1; then
    echo "❌ 失败: buckets_initialized 存在非原子赋值"
    exit 1
fi
echo "✅ 通过: buckets_initialized 使用原子操作"

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
