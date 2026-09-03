import http.server
import json
import sys


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
