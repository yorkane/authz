#!/usr/bin/env python3
"""Minimal WebSocket handshake endpoint used by the real gateway test."""

import base64
import hashlib
import socketserver
import sys


GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        data = b""
        while b"\r\n\r\n" not in data and len(data) < 16384:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            data += chunk
        lines = data.decode("iso-8859-1").split("\r\n")
        headers = {}
        for line in lines[1:]:
            if not line or ":" not in line:
                continue
            name, value = line.split(":", 1)
            headers[name.lower()] = value.strip()

        upgrade = headers.get("upgrade", "").lower()
        connection = headers.get("connection", "").lower()
        key = headers.get("sec-websocket-key", "")
        if not upgrade and lines[0].split(" ", 2)[1] == "/":
            body = b"""<!doctype html><script>
              const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
              const socket = new WebSocket(scheme + '://' + location.host + '/');
              socket.onmessage = event => { document.body.textContent = 'websocket:' + event.data; };
              socket.onerror = () => { document.body.textContent = 'websocket:error'; };
            </script>"""
            response = (
                b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: "
                + str(len(body)).encode("ascii")
                + b"\r\n\r\n"
                + body
            )
            self.request.sendall(response)
            return
        if upgrade != "websocket" or "upgrade" not in connection or not key:
            self.request.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return

        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode("ascii")
        self.request.sendall(response)
        self.request.sendall(b"\x81\x02ok")


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True


Server(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
