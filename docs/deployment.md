# ZigClaw v2.4 部署手册

> 本文档描述ZigClaw的编译、配置、运行和维护。

## 系统要求

- **操作系统**: Linux (内核 5.1+，支持 io_uring)
- **Zig版本**: 0.16.0 或更高
- **可选依赖**: Ollama (推理服务，http://localhost:11434)
- **内存**: 建议 512MB+ (取决于推理模型)
- **文件描述符**: 建议 ulimit -n 1024+

## 编译指令

### 1. 克隆仓库
```bash
git clone git@github.com:CWLtoken/ZigClaw-AI.git
cd ZigClaw-AI
git checkout agent  # 或 docs 分支查看文档
```

### 2. 编译项目
```bash
# 开发模式（快速编译）
zig build

# 发布模式（优化）
zig build -Drelease-fast

# 输出位置
ls zig-out/bin/zigclaw-http
```

### 3. 运行测试
```bash
# 全量测试（必须76/76全绿）
zig build test

# 单个测试
zig build test -fq -- integration_p41.test.P41
```

---

## 运行方式

### HTTP 服务器模式
```bash
# 默认端口8080
./zig-out/bin/zigclaw-http

# 自定义端口（如果支持）
./zig-out/bin/zigclaw-http --port 8080
```

### 预期输出
```
🌐 HTTP 服务器启动: http://127.0.0.1:8080/
等待连接...
```

### 优雅关闭
```bash
# 发送 SIGINT (Ctrl+C) 触发优雅关闭
# 服务器会：
# 1. 设置 running = false
# 2. 停止接受新连接
# 3. 等待现有连接处理完成
# 4. 释放资源并退出
```

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PORT` | 8080 | HTTP服务器监听端口 |
| `OLLAMA_URL` | http://localhost:11434 | Ollama推理服务地址 |
| `RUST_BACKTRACE` | 0 | Rust推理引擎的回溯（如果使用） |
| `ZIG_DEBUG` | 0 | ZigClaw调试输出（如果支持） |

---

## Ollama 配置

### 安装 Ollama (可选)
```bash
# Linux
curl -fsSL https://ollama.com/install.sh | sh

# 启动 Ollama 服务
ollama serve &

# 拉取模型（例如 llama3.2）
ollama pull llama3.2
```

### 验证 Ollama
```bash
# 检查服务
curl http://localhost:11434/api/tags

# 测试推理
curl http://localhost:11434/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Hello"
}'
```

### ZigClaw 与 Ollama 集成
- 如果 Ollama 不可用，ZigClaw 返回 503 Service Unavailable
- 日志显示：`[default] (warn): Ollama 调用失败: error.OllamaNotAvailable，返回错误响应`
- 不影响其他功能（如 /health 检查）

---

## API 端点

### 健康检查
```bash
# 基础检查
curl http://127.0.0.1:8080/health
# 返回: {"status":"ok","service":"zigclaw-http"}

# 详细指标（verbose模式）
curl http://127.0.0.1:8080/health?verbose=true
# 返回包含 uptime, total_requests, active_connections, error_count 的详细JSON
```

### 推理端点（需要Ollama）
```bash
# 文本推理
curl "http://127.0.0.1:8080/infer?input=如何优化性能&modality=text"

# 图像推理（如果支持）
curl "http://127.0.0.1:8080/infer?input=图片分析&modality=image"
```

### 其他端点
- `/` — 欢迎页面
- `/echo` — 回显测试
- `/status` — 服务状态（如果实现）

---

## 可观测性

### ServerMetrics（服务器指标）
- **实现**: `src/http_server.zig` 中的 `ServerMetrics` 结构体
- **原子操作**: 使用 `std.atomic.Value` 保证线程安全
- **指标**:
  - `total_requests` — 总请求数（原子递增）
  - `active_connections` — 活跃连接数（原子递增/递减）
  - `error_count` — 错误计数（原子递增）
  - `uptime_start` — 启动时间戳（当前简化版返回0）

### 日志输出
- 使用 `std.debug.print` 输出调试信息
- 格式：`📊`, `🌐`, `✅`, `⚠️` 等emoji前缀
- 示例：
  ```
  🌐 HTTP 服务器启动: http://127.0.0.1:8080/
  等待连接...
  /health 请求处理完成 (verbose=false)
  ```

---

## 故障排除

### 常见问题

#### 1. 编译错误：`std.time.milliTimestamp` 不存在
- **原因**: Zig 0.16 时间API变化
- **解决**: 已简化处理，`uptime` 暂时返回0，等待Zig 0.17

#### 2. 端口占用：Address already in use
```bash
# 查找占用进程
lsof -i :8080
# 杀死进程
kill -9 <PID>
```

#### 3. fd泄漏检测
```bash
# 查看进程fd使用
ls -la /proc/$(pgrep zigclaw-http)/fd | wc -l
```

#### 4. RSS内存增长
```bash
# 监控内存
watch -n 1 "ps aux | grep zigclaw-http | grep -v grep"
```

#### 5. Ollama不可用
- **现象**: 推理请求返回503
- **解决**: 检查Ollama服务，或接受降级（不影响/health）

---

## 生产部署建议

### 1. 使用 systemd 管理
```ini
# /etc/systemd/system/zigclaw.service
[Unit]
Description=ZigClaw HTTP Server
After=network.target

[Service]
Type=simple
User=zigclaw
WorkingDirectory=/opt/zigclaw
ExecStart=/opt/zigclaw/zig-out/bin/zigclaw-http
Restart=on-failure
RestartSec=5s
# 优雅关闭支持
KillSignal=SIGINT
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

### 2. 日志轮转
```bash
# 使用 systemd 的 journalctl 或配置 rsyslog
journalctl -u zigclaw -f
```

### 3. 监控告警
- 监控 `/health?verbose=true` 端点
- 设置告警：error_count 激增、active_connections 异常
- 集成 Prometheus（如果实现 `/metrics` 端点）

### 4. 安全加固
- 不要以 root 运行
- 使用防火墙限制访问（仅允许必要IP）
- 考虑添加 API Key 认证（如果暴露到公网）

---

## 版本与升级

### 当前版本
- **Version**: v2.4
- **Tag**: v5.4-p41-observability
- **Commit**: ceca9a6
- **测试**: 76/76 全绿 ✅

### 升级步骤
```bash
# 1. 拉取最新代码
git pull origin agent

# 2. 重新编译
zig build -Drelease-fast

# 3. 运行测试验证
zig build test

# 4. 重启服务
systemctl restart zigclaw
```

---

**维护者**: ZigClaw Team  
**最后更新**: 2026-05-06  
**架构师确认**: v2.4 进入收尾阶段，文档化完成。
