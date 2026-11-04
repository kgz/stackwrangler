#!/usr/bin/env bash
# DNS answers AWS → this container AND TLS :443 accepts a handshake.
set -euo pipefail
IP="$(hostname -i | awk '{print $1}')"
[[ -n "$IP" ]] || exit 1
ans="$(dig +short +time=1 +tries=1 @"$IP" sts.amazonaws.com A | head -1)"
[[ "$ans" == "$IP" ]] || exit 1
# Pid file alone is not enough (stale after kill); require an accept on :443.
python3 - <<'PY'
import socket, ssl, sys
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
try:
    with socket.create_connection(("127.0.0.1", 443), timeout=2) as raw:
        with ctx.wrap_socket(raw, server_hostname="sts.us-east-1.amazonaws.com") as s:
            s.sendall(
                b"HEAD / HTTP/1.1\r\n"
                b"Host: sts.us-east-1.amazonaws.com\r\n"
                b"Connection: close\r\n\r\n"
            )
            s.recv(64)
except OSError:
    sys.exit(1)
sys.exit(0)
PY
