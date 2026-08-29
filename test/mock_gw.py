import http.server
import ssl
import threading

BODY = b"hello-from-port-3456"


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *a):
        pass


httpd = http.server.ThreadingHTTPServer(("0.0.0.0", 3456), H)
httpsd = http.server.ThreadingHTTPServer(("0.0.0.0", 4567), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain("/data/agent/openresty-base/data/certs/default.crt", "/data/agent/openresty-base/data/certs/default.key")
httpsd.socket = ctx.wrap_socket(httpsd.socket, server_side=True)
threading.Thread(target=httpd.serve_forever, daemon=True).start()
httpsd.serve_forever()
