#!/usr/bin/env python3
"""服务发现计时回归的夹具：绑定 N 个只 LISTEN、永不 accept、不回应的 TCP 端口。

这些端口在 /proc/net/tcp 里是合法的 LISTEN 条目但没有任何流量痕迹，专门用来
给"过期即串行探测"的旧实现制造成本（每个端口吃掉一次 read 超时），并验证新
实现在同样的候选集下不再把请求路径拖慢。端口由内核挑选空闲口，避免与测试的
free_port 相撞；实际绑定的端口逐行打印 BOUND <port> 供脚本核对数量。
"""
import socket
import sys

want = int(sys.argv[1]) if len(sys.argv) > 1 else 24
socks = []
attempt = 0
while len(socks) < want and attempt < want * 20:
    attempt += 1
    sock = socket.socket()
    try:
        sock.bind(("127.0.0.1", 0))
        sock.listen(64)  # 故意不 accept：连接进 backlog，HEAD 永远等不到响应
    except OSError:
        sock.close()
        continue
    socks.append(sock)
    print(f"BOUND {sock.getsockname()[1]}", flush=True)

if len(socks) < want:
    print(f"SHORT {len(socks)}", flush=True)

import time
try:
    while True:
        time.sleep(3600)
except KeyboardInterrupt:
    pass
