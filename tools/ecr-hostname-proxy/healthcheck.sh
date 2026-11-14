#!/usr/bin/env bash
# TLS :443 accepts a handshake (SNI placeholder).
set -euo pipefail
python3 - <<'PY'
import socket, ssl, sys

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    with socket.create_connection(("127.0.0.1", 443), timeout=2) as raw:
        with ctx.wrap_socket(raw, server_hostname="000000000000.dkr.ecr.us-east-1.amazonaws.com") as s:
            s.sendall(
                b"GET /v2/ HTTP/1.1\r\n"
                b"Host: 000000000000.dkr.ecr.us-east-1.amazonaws.com\r\n"
                b"Connection: close\r\n\r\n"
            )
            s.recv(64)
    sys.exit(0)
except Exception as exc:
    print(exc, file=sys.stderr)
    sys.exit(1)
PY
