# ZigClaw v2.4 — 多阶段 Docker 构建
# 阶段1：用 Zig 0.16.0 静态编译二进制
FROM ziglang/zig:0.16.0 AS builder

WORKDIR /app

# 复制源代码
COPY src/ ./src/
COPY build.zig ./

# 静态编译 ZigClaw（无动态依赖）
# 目标：x86_64-linux-musl，生成静态链接的 ELF
RUN zig build-exe src/main.zig src/image_feature.c \
    -lc \
    -O ReleaseSafe \
    -target x86_64-linux-musl \
    --global-cache-dir /app/.zig-cache

# 阶段2：运行镜像（Alpine 3.18）
FROM alpine:3.18

RUN apk add --no-cache ca-certificates

WORKDIR /app

# 从构建阶段复制静态二进制
COPY --from=builder /app/main .

# 环境变量（通过 docker-compose 或运行时注入）
ENV OLLAMA_URL=http://ollama:11434
ENV API_KEY=changeme-in-production
ENV METRICS_PORT=9090
ENV PORT=8080

# 暴露端口（ZigClaw + Metrics）
EXPOSE 8080 9090

# 健康检查
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:8080/health || exit 1

# 启动 ZigClaw
CMD ["./main"]
