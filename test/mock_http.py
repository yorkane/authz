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
        if self.path == "/echo-body":
            # 请求改写测试端点：原样回显方法、Content-Type、Content-Length 与正文，
            # 用于验证网关的请求正文改写（替换/过滤）在转发前生效。
            length = int(self.headers.get("Content-Length") or 0)
            payload = self.rfile.read(length) if length else b""
            body = json.dumps({
                "method": self.command,
                "content_type": self.headers.get("Content-Type"),
                "content_length": self.headers.get("Content-Length"),
                "body": payload.decode("utf-8", "replace"),
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
        if self.path == "/rewrite-pcre":
            # PCRE 语义验证端点：正文含正则元字符（a.b / a|b）、可交换的捕获组、
            # 以及替换值里会被 ngx.re 展开的 $N 引用素材。
            payload = b"axb a.b a|b swap-7-3 cost$9\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
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
        if self.path == "/rewrite-utf8":
            # 多字节正文：拉丁 + 中文 + emoji，用于验证字节级改写与分块传输。
            payload = "Hello,\u4f60\u597d,\u4e16\u754c! \U0001f310 token=42\n".encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-empty":
            # 0 字节正文但声明 text/plain：验证改写规则在零字节场景下的语义。
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/rewrite-bin":
            # 已知 1024 字节二进制：用于 body_base64 字节级往返验证。
            payload = bytes(range(256)) * 4
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-chain":
            # 链式 filter 的多组响应头与正文样本；X-Trace 含多个分隔字段，便于头测试。
            payload = b"alpha\nbeta\ngamma\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("X-Trace", "first-second-third")
            self.send_header("X-Internal-Marker", "remove-me")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            print(f"[MOCK] sent payload len={len(payload)}", file=sys.stderr)
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
        if self.path == "/rewrite-negotiated":
            # 只在客户端声明支持压缩时返回 gzip。配置正文改写的绑定会把上游请求
            # 改成 identity，因此网关应拿到未压缩正文并成功改写。
            import gzip
            plain = b"negotiated-secret-token\n"
            encoding = "identity"
            payload = plain
            if "gzip" in self.headers.get("Accept-Encoding", ""):
                payload = gzip.compress(plain)
                encoding = "gzip"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Encoding", encoding)
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

        if self.path == "/rewrite-html-xss":
            # 含潜在危险脚本块的 HTML：用于验证网关可作为 XSS 净化层
            # 移除 <script>...</script>、内联事件属性以及 javascript: 链接。
            payload = (
                b'<!DOCTYPE html><html><head>'
                b'<script>alert("xss-token-SECRET123")</script>'
                b'<title>Hello &amp; welcome</title>'
                b'</head><body onload="steal()">'
                b'<a href="javascript:alert(1)">click</a>'
                b'<p>contact: admin@acme.example</p>'
                b'</body></html>'
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Server", "upstream-internal/9.9")
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-json":
            # 标准 JSON 响应：测试 Content-Type 替换与字段级过滤。
            body_obj = {
                "service": "checkout",
                "version": "1.0.0",
                "internal_secret": "leak-me-please",
                "endpoints": ["/pay", "/refund"],
                "owner": "team-acme",
            }
            payload = json.dumps(body_obj, indent=2).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("X-Backend", "checkout-svc")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-svg":
            # SVG 文本：image/svg+xml 在允许列表里，应可过滤。
            payload = (
                b'<?xml version="1.0" encoding="UTF-8"?>'
                b'<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
                b'<text x="0" y="9">SECRET-text</text>'
                b'</svg>'
            )
            self.send_response(200)
            self.send_header("Content-Type", "image/svg+xml")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-xml":
            # application/xml：允许过滤；用于验证多字节字符与嵌套标签处理。
            # 注意：\xe4\xba\xa7\xe5\x93\x81 是「产品」的 UTF-8 字节；
            # 双反斜杠会变成字面文本，网关过滤的是真实字节。
            # <meta> 的 UTF-8 属性名不在改写范围内，用于验证多字节字节流原样保留。
            payload = (
                b'<?xml version="1.0" encoding="UTF-8"?>'
                b'<order id="42"><item name="product">SECRET-xml</item>'
                b'<meta \xe4\xba\xa7\xe5\x93\x81="ok"/></order>'
            )
            self.send_response(200)
            self.send_header("Content-Type", "application/xml; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-css":
            # text/css：在允许列表里，应可过滤；用于覆盖 token 替换。
            payload = (
                b".btn { color: red; --brand-token: SECRET-css; }\n"
                b".btn:hover { color: blue; }\n"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/css; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-csv":
            # text/csv 不在允许列表里：body filter 应跳过滤过并标记 skipped=type。
            payload = b"id,name\n1,SECRET-csv\n2,plain\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/csv; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-multivalue":
            # 多值响应头：Vary 与 X-Trace 各带多个值；用于验证多值保留与重写。
            payload = b"line-1\nline-2 SECRET-mv\nline-3\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Vary", "Accept-Encoding, Accept-Language")
            self.send_header("X-Trace", "a, b, c")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-disposition":
            # 文件下载：Content-Disposition 带 filename*=UTF-8''... 形式。
            payload = b"%PDF-1.4\n%fake-pdf-bytes\nsecret=internal-pdf-token\n"
            self.send_response(200)
            self.send_header("Content-Type", "application/pdf")
            self.send_header("Content-Disposition", 'attachment; filename="internal.pdf"; filename*=UTF-8\'\'internal.pdf')
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-redirect":
            # 302 重定向：用于验证 Location 头可被改写且 status 转换语义正确。
            self.send_response(302)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Location", "https://internal.example/old-path")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/rewrite-stream":
            # 分块流式文本响应：每片独立写穿，验证 body_filter 在分片到达时
            # 能正确累积并最终产出过滤后的正文。
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for token in ("part-A SECRET-stream", "part-B plain",
                          "part-C SECRET-stream", "part-D end"):
                chunk = (token + "\n").encode()
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        if self.path == "/rewrite-empty-body":
            # 0 字节正文 + 文本 Content-Type：验证过滤规则在零字节场景下的语义。
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if self.path == "/rewrite-grow":
            # body 替换后比原正文更长：用于验证 Content-Length 被撤除、
            # 分块编码下大小变化能正确传递到客户端。
            payload = b"short"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if self.path == "/rewrite-shrink":
            # body 替换后比原正文更短：验证分块编码下大小缩减。
            payload = b"a-long-prefix-with-many-characters-that-will-be-replaced"
            self.send_response(200)
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
