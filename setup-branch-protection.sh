#!/bin/bash
# 配置GitHub分支保护规则
# 注意：这需要GitHub CLI (gh) 认证

# 设置main分支保护
echo "正在配置main分支保护规则..."

# 检查是否安装了gh CLI
if command -v gh &> /dev/null; then
    # 配置分支保护
    gh api repos/your-org/bitclaw/branches/main/protection --method PUT \
        -f required_status_checks='{"strict":true,"contexts":["ci"]}' \
        -f required_pull_request_reviews='{"required_approving_review_count":1}' \
        -f restrictions='null' \
        -f enforce_admins=false
    
    echo "✓ 分支保护规则已配置"
else
    echo "⚠ GitHub CLI (gh) 未安装，请手动配置分支保护规则"
    echo "  1. 进入仓库设置 -> 分支保护规则"
    echo "  2. 添加规则保护 'main' 分支"
    echo "  3. 启用以下选项:"
    echo "     - 要求PR审查 (1个审查者)"
    echo "     - 要求状态检查通过 (CI)"
    echo "     - 禁止强制推送"
    echo "     - 禁止删除分支"
fi
