#!/usr/bin/env python3
"""
ZigClaw 阶段23A 模拟服务器
模拟 HTTP 推理服务，用于测试真实部署场景
"""
import http.server
import socketserver
import urllib.parse
import json
import sys

PORT = 8080

class ZigClawHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parsed_path = urllib.parse.urlparse(self.path)
        path = parsed_path.path
        query = urllib.parse.parse_qs(parsed_path.query)

        if path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "service": "zigclaw-sim"}).encode())
            print(f"✓ /health 响应成功")
            return

        if path == "/infer":
            input_text = query.get("input", [""])[0]
            modality = query.get("modality", ["text"])[0]

            if not input_text:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"error": "Missing 'input' parameter"}).encode())
                return

            # 模拟推理过程
            print(f"推理请求: input='{input_text}', modality='{modality}'")
            result = f"模拟推理结果: {input_text[:50]}..."

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Connection", "close")
            self.end_headers()
            response = json.dumps({
                "input": input_text,
                "modality": modality,
                "result": result,
                "status": "success"
            })
            self.wfile.write(response.encode())
            print(f"✓ /infer 响应成功")
            return

        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"Not Found")

    def log_message(self, format, *args):
        pass  # 禁用默认日志

if __name__ == "__main__":
    with socketserver.TCPServer(("", PORT), ZigClawHandler) as httpd:
        print(f"🌐 ZigClaw 模拟服务器启动: http://127.0.0.1:{PORT}/")
        print("   路由：")
        print("     GET /health → 健康检查")
        print("     GET /infer?input=xxx&modality=text|image → 推理")
        print("   按 Ctrl+C 停止服务器")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print("\n服务器停止")
            sys.exit(0)