# ZigClaw v2.4 部署文档

## 目录
- [容器化部署](#容器化部署)
- [前置条件](#前置条件)
- [快速开始](#快速开始)
- [配置说明](#配置说明)
- [验证部署](#验证部署)
- [生产环境建议](#生产环境建议)
- [故障排查](#故障排查)

---

## 容器化部署

ZigClaw v2.4 提供完整的 Docker 容器化方案，包含三个服务：
- **zigclaw**：主服务（静态编译的 Zig 二进制）
- **ollama**：本地 LLM 推理引擎
- **nginx**：TLS 终止 + 反向代理

---

## 前置条件

- Docker 20.10+
- Docker Compose 1.29+
- 至少 4GB RAM（Ollama 模型加载）
- 至少 10GB 磁盘空间

---

## 快速开始

### 1. 克隆仓库
```bash
git clone https://github.com/CWLtoken/ZigClaw-AI.git
cd ZigClaw-AI
```

### 2. 生成 TLS 证书（自签名）
```bash
./scripts/generate_certs.sh
```
生成位置：`./certs/server.crt` 和 `./certs/server.key`

### 3. 配置环境变量（可选）
创建 `.env` 文件：
```bash
cat > .env <<EOF
ZIGCLAW_PORT=8080
METRICS_PORT=9090
API_KEY=your-secure-api-key-here
EOF
```

### 4. 启动服务栈
```bash
docker-compose up -d
```

首次启动会：
- 构建 ZigClaw 静态二进制（多阶段构建）
- 拉取 Ollama 和 Nginx 镜像
- 启动所有服务

### 5. 查看日志
```bash
docker-compose logs -f zigclaw
```

---

## 配置说明

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `ZIGCLAW_PORT` | 8080 | ZigClaw HTTP 端口 |
| `METRICS_PORT` | 9090 | Prometheus 指标端口 |
| `API_KEY` | changeme-in-production | API 认证密钥 |
| `OLLAMA_URL` | http://ollama:11434 | Ollama 服务地址（容器内） |

### 端口映射

| 服务 | 容器内端口 | 宿主机端口 | 说明 |
|------|-----------|-----------|------|
| zigclaw | 8080 | 8080 | HTTP API |
| zigclaw | 9090 | 9090 | Prometheus 指标 |
| ollama | 11434 | 11434 | Ollama API |
| nginx | 80 | 80 | HTTP（重定向到 HTTPS） |
| nginx | 443 | 443 | HTTPS（TLS 终止） |

---

## 验证部署

### 1. 检查服务健康状态
```bash
docker-compose ps
```
所有服务应为 `Up (healthy)` 状态。

### 2. 测试健康检查（直接访问）
```bash
curl http://localhost:8080/health
```
预期响应：
```json
{"status": "ok"}
```

### 3. 测试 HTTPS 访问（通过 Nginx）
```bash
curl -k https://localhost/health
```
`-k` 跳过自签名证书验证。

### 4. 测试 Prometheus 指标
```bash
curl http://localhost:9090/metrics
```
或通过 Nginx：
```bash
curl -k https://localhost/metrics
```

### 5. 测试推理功能
```bash
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer your-api-key" \
  -d '{"model": "llama2", "messages": [{"role": "user", "content": "Hello"}]}'
```

---

## 生产环境建议

### 1. TLS 证书
不要用自签名证书！使用：
- **Let's Encrypt**（推荐）：`certbot` + `nginx`
- **商业证书**：购买后替换 `certs/` 目录下的文件

修改 `nginx.conf` 中的证书路径，或通过卷挂载覆盖。

### 2. API Key 安全
- 使用强随机密钥：`openssl rand -hex 32`
- 不要提交 `.env` 到 Git
- 考虑使用 Docker Secrets 或 Vault

### 3. Ollama 模型管理
默认 Ollama 不预装模型，首次需要拉取：
```bash
docker exec ollama ollama pull llama2
```

### 4. 资源限制
在 `docker-compose.yml` 中添加：
```yaml
deploy:
  resources:
    limits:
      cpus: '2'
      memory: 4G
```

### 5. 日志管理
配置 logrotate 或使用 Docker 日志驱动：
```yaml
logging:
  driver: "json-file"
  options:
    max-size: "10m"
    max-file: "3"
```

---

## 故障排查

### 服务无法启动

**查看日志**：
```bash
docker-compose logs zigclaw
docker-compose logs ollama
docker-compose logs nginx
```

**检查健康状态**：
```bash
docker inspect zigclaw | jq '.[0].State.Health'
```

### ZigClaw 编译失败

进入 builder 容器调试：
```bash
docker-compose build --progress=plain zigclaw
```

检查 Zig 版本：
```bash
docker run --rm ziglang/zig:0.16.0 zig version
```

### Ollama 无法连接

检查网络：
```bash
docker exec zigclaw ping ollama
docker exec ollama ollama list
```

### Nginx TLS 错误

检查证书：
```bash
openssl x509 -in certs/server.crt -text -noout
```

检查 Nginx 配置：
```bash
docker exec zigclaw-nginx nginx -t
```

---

## 停止服务

```bash
docker-compose down
```

保留数据卷（Ollama 模型）：
```bash
docker-compose down --volumes  # 会删除 Ollama 数据！
```

---

## 版本信息

- ZigClaw：v2.4 (v6.0.0-final)
- Zig：0.16.0
- Alpine：3.18
- Nginx：1.25-alpine
- Ollama：0.1.26

---

**文档版本**：2026-05-06
**维护者**：ZigClaw Team
