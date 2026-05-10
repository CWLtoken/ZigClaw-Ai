#!/bin/bash
# generate_certs.sh — 为 ZigClaw Nginx 生成自签名 TLS 证书
# 用法：./scripts/generate_certs.sh

set -e

CERTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../certs" && pwd)"
mkdir -p "$CERTS_DIR"

CERT_FILE="$CERTS_DIR/server.crt"
KEY_FILE="$CERTS_DIR/server.key"

if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
    echo "证书已存在：$CERT_FILE"
    echo "如需重新生成，请删除现有证书后重新运行。"
    exit 0
fi

echo "正在生成自签名证书..."

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/C=US/ST=State/L=City/O=ZigClaw/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

chmod 600 "$KEY_FILE"
chmod 644 "$CERT_FILE"

echo "✅ 证书生成完成："
echo "   证书：$CERT_FILE"
echo "   私钥：$KEY_FILE"
echo ""
echo "注意：这是自签名证书，浏览器会显示安全警告。"
echo "生产环境请使用 Let's Encrypt 或商业证书。"
