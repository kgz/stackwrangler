#!/usr/bin/env python3
"""TLS edge for aws-redirect: dynamic SNI leafs → LocalEmu HTTP, Host preserved."""
from __future__ import annotations

import asyncio
import logging
import os
import re
import ssl
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

LOG = logging.getLogger("aws-redirect.tls")

HOSTNAME_RE = re.compile(r"^[A-Za-z0-9._*-]+$")
CERT_DIR = Path(os.environ.get("AWS_REDIRECT_CERT_DIR", "/certs"))
UPSTREAM = os.environ.get("LOCALEMU_URL", "http://localstack:4566").rstrip("/")
LISTEN_HOST = os.environ.get("AWS_REDIRECT_TLS_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("AWS_REDIRECT_TLS_PORT", "443"))
PID_FILE = Path(os.environ.get("AWS_REDIRECT_TLS_PID", "/var/run/aws-redirect-tls.pid"))


def _parse_upstream(url: str) -> tuple[str, int]:
    if url.startswith("https://"):
        rest = url[len("https://") :]
        default_port = 443
    elif url.startswith("http://"):
        rest = url[len("http://") :]
        default_port = 80
    else:
        rest = url
        default_port = 80
    host_port = rest.split("/", 1)[0]
    if ":" in host_port:
        host, port_s = host_port.rsplit(":", 1)
        return host, int(port_s)
    return host_port, default_port


UP_HOST, UP_PORT = _parse_upstream(UPSTREAM)


def _load_ca() -> tuple[rsa.RSAPrivateKey, x509.Certificate]:
    key_pem = (CERT_DIR / "ca.key").read_bytes()
    crt_pem = (CERT_DIR / "ca.crt").read_bytes()
    key = serialization.load_pem_private_key(key_pem, password=None)
    if not isinstance(key, rsa.RSAPrivateKey):
        raise SystemExit("CA key must be RSA")
    cert = x509.load_pem_x509_certificate(crt_pem)
    return key, cert


def _normalize_host(hostname: str | None) -> str:
    host = (hostname or "").strip(".").lower() or "amazonaws.com"
    if not HOSTNAME_RE.match(host) or len(host) > 253:
        return "amazonaws.com"
    return host


class CertCache:
    def __init__(self, ca_key: rsa.RSAPrivateKey, ca_cert: x509.Certificate) -> None:
        self._ca_key = ca_key
        self._ca_cert = ca_cert
        self._ctx: dict[str, ssl.SSLContext] = {}

    def _write_pair(self, hostname: str, cert_pem: bytes, key_pem: bytes) -> tuple[str, str]:
        leaf_dir = CERT_DIR / "leafs"
        leaf_dir.mkdir(parents=True, exist_ok=True)
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", hostname)[:200]
        crt_path = leaf_dir / f"{safe}.crt"
        key_path = leaf_dir / f"{safe}.key"
        crt_path.write_bytes(cert_pem)
        key_path.write_bytes(key_pem)
        return str(crt_path), str(key_path)

    def context_for(self, hostname: str | None) -> ssl.SSLContext:
        host = _normalize_host(hostname)
        hit = self._ctx.get(host)
        if hit is not None:
            return hit

        leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        now = datetime.now(timezone.utc)
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, host[:64])])
        leaf = (
            x509.CertificateBuilder()
            .subject_name(name)
            .issuer_name(self._ca_cert.subject)
            .public_key(leaf_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=5))
            .not_valid_after(now + timedelta(days=30))
            .add_extension(
                x509.SubjectAlternativeName([x509.DNSName(host)]),
                critical=False,
            )
            .add_extension(
                x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),
                critical=False,
            )
            .add_extension(
                x509.BasicConstraints(ca=False, path_length=None),
                critical=True,
            )
            .sign(private_key=self._ca_key, algorithm=hashes.SHA256())
        )
        cert_pem = leaf.public_bytes(serialization.Encoding.PEM)
        key_pem = leaf_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )
        crt_path, key_path = self._write_pair(host, cert_pem, key_pem)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2
        ctx.load_cert_chain(certfile=crt_path, keyfile=key_path)
        self._ctx[host] = ctx
        LOG.info("minted leaf for %s", host)
        return ctx


def _header_value(headers: list[bytes], name: bytes) -> bytes | None:
    prefix = name.lower() + b":"
    for raw in headers:
        if raw.lower().startswith(prefix):
            return raw.split(b":", 1)[1].strip()
    return None


async def _pipe_request(
    client_r: asyncio.StreamReader,
    up_w: asyncio.StreamWriter,
) -> None:
    req_line = await client_r.readline()
    if not req_line:
        return
    headers: list[bytes] = []
    while True:
        line = await client_r.readline()
        if not line or line in (b"\r\n", b"\n"):
            break
        headers.append(line)

    filtered: list[bytes] = []
    for h in headers:
        low = h.lower()
        if low.startswith(b"accept-encoding:"):
            continue
        if low.startswith(b"connection:"):
            continue
        filtered.append(h)
    filtered.append(b"Connection: close\r\n")

    up_w.write(req_line)
    for h in filtered:
        up_w.write(h)
    up_w.write(b"\r\n")

    cl_raw = _header_value(headers, b"content-length")
    te_raw = _header_value(headers, b"transfer-encoding")
    if cl_raw is not None:
        remaining = int(cl_raw.decode("ascii", errors="ignore") or "0")
        while remaining > 0:
            chunk = await client_r.read(min(65536, remaining))
            if not chunk:
                break
            up_w.write(chunk)
            remaining -= len(chunk)
    elif te_raw is not None and b"chunked" in te_raw.lower():
        while True:
            size_line = await client_r.readline()
            up_w.write(size_line)
            try:
                size = int(size_line.strip().split(b";")[0], 16)
            except ValueError:
                break
            if size == 0:
                trailer = await client_r.readline()
                up_w.write(trailer)
                break
            data = await client_r.readexactly(size)
            up_w.write(data)
            crlf = await client_r.readexactly(2)
            up_w.write(crlf)
    await up_w.drain()


async def _pipe_response(
    up_r: asyncio.StreamReader,
    client_w: asyncio.StreamWriter,
) -> None:
    while True:
        data = await up_r.read(65536)
        if not data:
            break
        client_w.write(data)
        await client_w.drain()


async def _handle(
    client_r: asyncio.StreamReader,
    client_w: asyncio.StreamWriter,
) -> None:
    peer = client_w.get_extra_info("peername")
    try:
        up_r, up_w = await asyncio.open_connection(UP_HOST, UP_PORT)
    except OSError as exc:
        LOG.warning("upstream %s:%s unreachable: %s", UP_HOST, UP_PORT, exc)
        client_w.close()
        await client_w.wait_closed()
        return
    try:
        await _pipe_request(client_r, up_w)
        await _pipe_response(up_r, client_w)
    except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError) as exc:
        LOG.debug("proxy session %s ended: %s", peer, exc)
    finally:
        up_w.close()
        try:
            await up_w.wait_closed()
        except Exception:
            pass
        client_w.close()
        try:
            await client_w.wait_closed()
        except Exception:
            pass


async def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stderr,
    )
    ca_key, ca_cert = _load_ca()
    cache = CertCache(ca_key, ca_cert)
    bootstrap = cache.context_for("amazonaws.com")

    def on_sni(sock: ssl.SSLObject, server_name: str | None, _initial: ssl.SSLContext) -> None:
        sock.context = cache.context_for(server_name)

    bootstrap.sni_callback = on_sni

    PID_FILE.parent.mkdir(parents=True, exist_ok=True)
    PID_FILE.write_text(str(os.getpid()))
    server = await asyncio.start_server(
        _handle,
        host=LISTEN_HOST,
        port=LISTEN_PORT,
        ssl=bootstrap,
        reuse_address=True,
    )
    socks = ", ".join(str(s.getsockname()) for s in server.sockets or [])
    LOG.info("TLS edge on %s → %s:%s (pid %s)", socks, UP_HOST, UP_PORT, os.getpid())
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
