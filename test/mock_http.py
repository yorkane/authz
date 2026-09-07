import http.server
import json
import sys
import time


BODY = (sys.argv[3] if len(sys.argv) > 3 else "hello-from-authz-mock").encode()


class Handler(http.server.BaseHTTPRequestHandler):
    def respond(self):
        if self.path.startswith("/backend"):
            body = self.path.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/trusted-origin":
            forwarded_proto = self.headers.get("X-Forwarded-Proto") or "http"
            expected_origin = f"{forwarded_proto}://{self.headers.get('Host')}"
            origin = self.headers.get("Origin")
            body = json.dumps({
                "origin": origin,
                "expected_origin": expected_origin,
            }, separators=(",", ":")).encode()
            status = 200 if origin == expected_origin else 403
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/identity":
            body = json.dumps({
                "user": self.headers.get("X-Authz-User"),
                "source": self.headers.get("X-Authz-Source"),
                "identity": self.headers.get("X-Authz-Identity"),
                "authz_key": self.headers.get("X-Authz-Key"),
                "host": self.headers.get("Host"),
                "origin": self.headers.get("Origin"),
                "forwarded_host": self.headers.get("X-Forwarded-Host"),
                "forwarded_proto": self.headers.get("X-Forwarded-Proto"),
                "forwarded_port": self.headers.get("X-Forwarded-Port"),
               "real_ip": self.headers.get("X-Real-IP"),
               "forwarded_for": self.headers.get("X-Forwarded-For"),
               "forwarded": self.headers.get("Forwarded"),
               "cookie": self.headers.get("Cookie"),
                "probe": self.headers.get("X-Probe-Header"),
                "authorization": self.headers.get("Authorization"),
            }, separators=(",", ":")).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/rewrite":
            # 响应改写测试端点：文本正文 + 可被改写/删除的响应头。
            payload = ("Hello Rewrite\ninternal-secret-token\nbrand=Acme\n"
                       "value=42\n").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("X-Upstream-Trace", "upstream-trace")
            self.send_header("X-Upstream-Remove", "remove-me")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-html":
            payload = b"<html><body>HOME - Acme page</body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-binary":
            payload = bytes(range(256)) * 8
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-large":
            payload = b"chunk-" + b"x" * 200000 + b"\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-slow":
            # 慢速流式响应：让并发的正文改写长时间占用 worker 缓冲预算。
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            for index in range(40):
                self.wfile.write(b"stream-secret-%d " % index + b"s" * 900 + b"\n")
                self.wfile.flush()
                time.sleep(0.15)
            return
        if self.path == "/rewrite-huge":
            # 超过网关缓冲上限：必须放弃改写并完整透传。
            payload = b"chunk-" + b"y" * 1200000 + b"\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-gzip":
            # 始终返回 gzip 编码：验证网关跳过对已压缩正文的改写。
            import gzip
            payload = gzip.compress(b"plain-text-inside-gzip\n")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Encoding", "gzip")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-error":
            payload = b"upstream failure"
            self.send_response(503)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def log_message(self, *args):
        pass


port = int(sys.argv[1]) if len(sys.argv) > 1 else 3456
bind_ip = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
http.server.ThreadingHTTPServer((bind_ip, port), Handler).serve_forever()
