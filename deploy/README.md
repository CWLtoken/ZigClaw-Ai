# 部署配置

## 目录结构

```
deploy/
├── Dockerfile          # 多阶段构建：Zig 0.16 静态编译 → Alpine
├── docker-compose.yml  # ZigClaw + Ollama + Nginx 三服务编排
├── nginx/
│   └── nginx.conf      # TLS 终止 + 反向代理
└── certs/
    └── generate_certs.sh  # 自签名证书生成脚本
```

## 快速启动

```bash
# 生成证书（首次）
cd deploy/certs && bash generate_certs.sh

# 启动全部服务
cd deploy && docker-compose up -d

# 验证
curl -k https://localhost/health
curl http://localhost:9090/metrics
```

## 说明

- Dockerfile 使用多阶段构建，最终镜像基于 Alpine，仅含静态二进制
- Nginx 负责 TLS 终止（/ → zigclaw:8080，/metrics → zigclaw:9090）
- 证书为自签名，仅限开发/测试环境使用
