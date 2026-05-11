# ZigClaw-AI 文档导航

## 新读者阅读顺序

> **首次接触 ZigClaw-AI？按以下顺序阅读，避免在文档森林中迷路。**

### 第一步：了解全貌
1. **[README](../README.md)** — 项目名片，快速了解是什么、能做什么、怎么跑起来
2. **[架构文档](architecture.md)** — 六层架构、模块拓扑、数据流，建立整体心智模型

### 第二步：动手运行
3. **[部署手册](deployment.md)** — 编译、运行、Docker、TLS，让服务跑起来

### 第三步：深入开发
4. **[军规文档](military_rules.md)** — 无菌室、精确导入、错误处理三大军规，**写代码前必读**
5. **[踩坑记录](pitfalls.md)** — E1–E33 永久法则，避免重蹈覆辙
6. **[架构纠偏](corrections.md)** — D1–D8 纠偏记录，理解架构演进中的关键决策

### 第四步：阶段演进
7. **[阶段演进](phases.md)** — P0–P60 演进时序，了解每个阶段解决了什么问题

### 第五步：质量保障
8. **[CI 规范](ci_code_review.md)** — 8 条 CI 检查规则，提交代码前的自检清单

### 版本与归档
9. **[RELEASES](../RELEASES.md)** — 版本发布说明（用户视角）
10. **[CHANGELOG](../CHANGELOG.md)** — 开发阶段演进（开发者视角）
11. **[架构分析](architecture-analysis.md)** — 完整架构分析文档（深度参考）

---

## 快速索引

| 我想... | 读哪个文档 |
|---------|-----------|
| 第一次了解项目 | README → architecture.md |
| 本地编译运行 | deployment.md |
| 理解代码规范 | military_rules.md → ci_code_review.md |
| 调试一个诡异 bug | pitfalls.md → corrections.md |
| 了解某个阶段做了什么 | phases.md |
| 提交代码前自检 | ci_code_review.md |
| 查看版本变更 | RELEASES.md / CHANGELOG.md |
|| 理解军规细节 | military_rules.md |
|| 查看错误注入测试 | test_integration/fault_injection.zig（代码即文档） |
|| 显性直白设计哲学 | military_rules.md → 显性直白章节 |
|| 无依赖0供应链安全 | military_rules.md → 无依赖0章节 |
|| 架构师审计修复记录 | military_rules.md → v3.1 审计修复记录 |
|| P0/P1/P2 问题分级 | military_rules.md → 审计结论 |

---

## 军规速查

| 军规 | 核心规则 | 检查命令 |
|------|----------|----------|
| **第一诫** | 禁止 `const std = @import("std")` | `grep -rn 'const std =' src/ --include='*.zig'` |
| **第二诫** | 无菌室禁止 `try/catch/orelse` | `grep -rn '\<try\>' src/reactor.zig src/io_uring.zig src/protocol.zig` |
| **第三诫** | 零第三方依赖 | 检查 `@import` 是否引用外部包 |
| **构建军规** | 禁止 `addSystemCommand` | 检查 `build.zig` 构建方式 |
| **测试军规** | 错误注入 + 编译期守卫 | `zig build test` |

---

## 架构决策索引

| 决策 | 文档位置 |
|------|----------|
| 为什么选择 io_uring | architecture.md |
| 为什么六层分层 | architecture.md → military_rules.md |
| 为什么禁止 try/catch | military_rules.md → 第二诫 |
| 为什么精确导入 | military_rules.md → 第一诫 |
| 为什么零依赖 | military_rules.md → 第三诫 |
| 为什么 BATCH_THRESHOLD=8 | phases.md → P2 |
| 为什么连接池用状态机 | phases.md → P4 |
| 为什么错误注入测试 | phases.md → P5 |
