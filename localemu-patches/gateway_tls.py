"""LocalEmu gateway TLS material for ECS (and other) workloads (#687).

LocalEmu already multiplexes HTTPS on :4566, but the default self-signed
leaf only lists localhost / 127.0.0.1. Tasks dial the compose-network IP
(or ``localemu.awsbox`` via ``--add-host``), so verification fails and
IAM correctly sets ``aws:SecureTransport=false`` for plain ``http://``
``AWS_ENDPOINT_URL``.

This module:
  * mints a local CA + leaf with those SANs
  * overwrites LocalEmu's ``server.test.pem`` before the gateway loads it
  * publishes the CA under ``/var/lib/awsbox/tls`` (compose ``./.awsbox``)
    so ECS can bind-mount it and set ``AWS_CA_BUNDLE`` /
    ``NODE_EXTRA_CA_CERTS`` / ``SSL_CERT_FILE``
"""

from __future__ import annotations

import ipaddress
import logging
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOG = logging.getLogger("localemu.awsbox.gateway_tls")

TLS_DIR = Path("/var/lib/awsbox/tls")
CA_CERT_NAME = "ca.crt"
CA_BUNDLE_NAME = "ca-bundle.crt"
CA_KEY_NAME = "ca.key"
LEAF_CERT_NAME = "server.crt"
LEAF_KEY_NAME = "server.key"
EMU_DNS_NAME = "localemu.awsbox"
TASK_CA_DIR = "/etc/awsbox/certs"


def ensure_gateway_tls() -> Path:
    """Create/refresh CA + leaf and install into LocalEmu's SSL cache.

    Safe to call on every start; always rewrites so compose-network IP
    changes are reflected in the SAN list.
    """
    TLS_DIR.mkdir(parents=True, exist_ok=True)
    sans_dns, sans_ip = _san_lists()
    ca_cert_pem, ca_key_pem, leaf_cert_pem, leaf_key_pem = _mint_ca_and_leaf(
        sans_dns, sans_ip
    )

    ca_crt = TLS_DIR / CA_CERT_NAME
    ca_key = TLS_DIR / CA_KEY_NAME
    leaf_crt = TLS_DIR / LEAF_CERT_NAME
    leaf_key = TLS_DIR / LEAF_KEY_NAME
    bundle = TLS_DIR / CA_BUNDLE_NAME

    ca_crt.write_bytes(ca_cert_pem)
    ca_key.write_bytes(ca_key_pem)
    leaf_crt.write_bytes(leaf_cert_pem)
    leaf_key.write_bytes(leaf_key_pem)
    ca_key.chmod(0o600)
    leaf_key.chmod(0o600)

    bundle_parts = [_system_ca_bundle_bytes(), ca_cert_pem]
    bundle.write_bytes(b"".join(p for p in bundle_parts if p))

    _install_localemu_server_pem(leaf_cert_pem, leaf_key_pem)
    LOG.info(
        "gateway TLS ready dns=%s ips=%s ca=%s",
        ",".join(sans_dns),
        ",".join(sans_ip),
        ca_crt,
    )
    return ca_crt


def task_ca_host_paths() -> tuple[str | None, str | None]:
    """Docker-host paths for ``ca.crt`` and ``ca-bundle.crt`` (BindMount)."""
    ca = _resolve_host_bind(str(TLS_DIR / CA_CERT_NAME))
    bundle = _resolve_host_bind(str(TLS_DIR / CA_BUNDLE_NAME))
    return ca, bundle


def inject_task_tls_trust(env_vars: dict, volumes) -> None:
    """Bind-mount gateway CA into the task and set SDK trust env vars."""
    ca_ctr_src = TLS_DIR / CA_CERT_NAME
    bundle_ctr_src = TLS_DIR / CA_BUNDLE_NAME
    # Existence is checked on the LocalEmu-visible path; BindMount needs the
    # Docker-host path (./.awsbox/…), which is not visible inside this netns.
    if not ca_ctr_src.is_file() or not bundle_ctr_src.is_file():
        LOG.warning("gateway CA files missing (%s); skip mount", ca_ctr_src)
        return
    ca_host, bundle_host = task_ca_host_paths()
    if not ca_host or not bundle_host:
        LOG.warning(
            "gateway CA host path unresolved; tasks may fail TLS verify (#687)"
        )
        return

    from localemu.utils.container_utils.container_client import BindMount

    ca_ctr = f"{TASK_CA_DIR}/{CA_CERT_NAME}"
    bundle_ctr = f"{TASK_CA_DIR}/{CA_BUNDLE_NAME}"
    volumes.append(BindMount(ca_host, ca_ctr, read_only=True))
    volumes.append(BindMount(bundle_host, bundle_ctr, read_only=True))
    env_vars["AWS_CA_BUNDLE"] = bundle_ctr
    env_vars["SSL_CERT_FILE"] = bundle_ctr
    env_vars["NODE_EXTRA_CA_CERTS"] = ca_ctr
    env_vars["REQUESTS_CA_BUNDLE"] = bundle_ctr
    env_vars["CURL_CA_BUNDLE"] = bundle_ctr


def _san_lists() -> tuple[list[str], list[str]]:
    dns = ["localhost", "test.localhost.atlassian.io", EMU_DNS_NAME]
    ips = ["127.0.0.1"]
    try:
        from localemu.services.ec2.docker.vpc_endpoint import _localemu_gateway

        gw_ip, _net = _localemu_gateway()
        if gw_ip:
            ips.append(gw_ip)
    except Exception:
        LOG.debug("gateway IP for TLS SAN unavailable", exc_info=True)
    try:
        import socket

        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addr = info[4][0]
            if addr and not addr.startswith("127."):
                ips.append(addr)
    except Exception:
        LOG.debug("hostname IPs for TLS SAN skipped", exc_info=True)
    # de-dupe, preserve order
    dns_out: list[str] = []
    for d in dns:
        if d not in dns_out:
            dns_out.append(d)
    ip_out: list[str] = []
    for ip in ips:
        if ip not in ip_out:
            ip_out.append(ip)
    return dns_out, ip_out


def _mint_ca_and_leaf(
    dns_names: list[str], ip_names: list[str]
) -> tuple[bytes, bytes, bytes, bytes]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

    now = datetime.now(timezone.utc)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name(
        [
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "stackwrangler"),
            x509.NameAttribute(NameOID.COMMON_NAME, "stackwrangler LocalEmu CA"),
        ]
    )
    ca_cert = (
        x509.CertificateBuilder()
        .subject_name(ca_name)
        .issuer_name(ca_name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .sign(private_key=ca_key, algorithm=hashes.SHA256())
    )

    leaf_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    leaf_name = x509.Name(
        [
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "stackwrangler"),
            x509.NameAttribute(NameOID.COMMON_NAME, "localhost"),
        ]
    )
    san: list[x509.GeneralName] = [x509.DNSName(d) for d in dns_names]
    for ip in ip_names:
        try:
            san.append(x509.IPAddress(ipaddress.ip_address(ip)))
        except ValueError:
            continue
    leaf_cert = (
        x509.CertificateBuilder()
        .subject_name(leaf_name)
        .issuer_name(ca_name)
        .public_key(leaf_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=825))
        .add_extension(x509.SubjectAlternativeName(san), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=True,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]),
            critical=False,
        )
        .sign(private_key=ca_key, algorithm=hashes.SHA256())
    )

    def _pem_cert(c: x509.Certificate) -> bytes:
        return c.public_bytes(serialization.Encoding.PEM)

    def _pem_key(k: rsa.RSAPrivateKey) -> bytes:
        return k.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        )

    return _pem_cert(ca_cert), _pem_key(ca_key), _pem_cert(leaf_cert), _pem_key(leaf_key)


def _system_ca_bundle_bytes() -> bytes:
    for candidate in (
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/pki/tls/certs/ca-bundle.crt",
        "/etc/ssl/cert.pem",
    ):
        try:
            data = Path(candidate).read_bytes()
            if data.strip():
                if not data.endswith(b"\n"):
                    data += b"\n"
                return data
        except OSError:
            continue
    return b""


def _install_localemu_server_pem(cert_pem: bytes, key_pem: bytes) -> None:
    """Overwrite LocalEmu's default combined PEM (+ split .crt/.key)."""
    try:
        from localemu.utils.ssl import get_cert_pem_file_path
    except Exception:
        LOG.warning("localemu ssl helpers unavailable; skip server.pem install")
        return

    target = Path(get_cert_pem_file_path())
    target.parent.mkdir(parents=True, exist_ok=True)
    combined = key_pem.rstrip(b"\n") + b"\n" + cert_pem
    if not cert_pem.endswith(b"\n"):
        combined += b"\n"
    target.write_bytes(combined)
    Path(f"{target}.key").write_bytes(key_pem)
    Path(f"{target}.crt").write_bytes(cert_pem)
    Path(f"{target}.key").chmod(0o600)


def _resolve_host_bind(container_abs: str) -> str | None:
    """Map a path inside this container to the Docker daemon host path."""
    best: str | None = None
    best_len = -1
    try:
        with open("/proc/self/mountinfo", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) < 10:
                    continue
                root, mnt = parts[3], parts[4]
                mnt_n = mnt.rstrip("/") or "/"
                path_n = container_abs.rstrip("/") or "/"
                if path_n == mnt_n or path_n.startswith(mnt_n + "/"):
                    if len(mnt_n) < best_len:
                        continue
                    rel = path_n[len(mnt_n) :].lstrip("/")
                    best = os.path.join(root, rel) if rel else root
                    best_len = len(mnt_n)
    except OSError:
        LOG.debug("mountinfo read failed", exc_info=True)
        return None
    return best
