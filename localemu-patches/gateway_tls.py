"""LocalEmu gateway TLS material for ECS / Lambda / EC2 workloads (#687, #696).

LocalEmu already multiplexes HTTPS on :4566, but the default self-signed
leaf only lists localhost / 127.0.0.1. Workloads dial the compose-network
IP (or ``localemu.awsbox`` via ``--add-host``), so verification fails and
IAM correctly sets ``aws:SecureTransport=false`` for plain ``http://``
``AWS_ENDPOINT_URL``.

This module:
  * mints a local CA + leaf with those SANs (CA reused across restarts)
  * installs the leaf into LocalEmu's ``server.test.pem`` *before*
    gateway SSL init (boot.d) so ``create_ssl_cert`` keeps our files
  * publishes the CA under ``/var/lib/awsbox/tls`` (compose ``./.awsbox``)
    so ECS / Lambda / EC2 can bind-mount it and set ``AWS_CA_BUNDLE`` /
    ``NODE_EXTRA_CA_CERTS`` / ``SSL_CERT_FILE``

Reminting the CA on every start breaks verification: tasks mount the new
CA from ``.awsbox`` while the live gateway still serves the previous leaf
(or a leaf signed by the previous CA). Keep the CA stable; only refresh
the leaf when SANs change.
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


def ensure_gateway_tls(*, force_remint: bool = False) -> Path:
    """Ensure CA + leaf exist and are installed into LocalEmu's SSL cache.

    Safe to call from boot.d (before gateway SSL) and start.d (idempotent).
    Reuses the on-disk CA unless ``force_remint``; remints the leaf only when
    SANs drift (compose-network IP change) or material is missing.
    """
    TLS_DIR.mkdir(parents=True, exist_ok=True)
    sans_dns, sans_ip = _san_lists()

    ca_crt = TLS_DIR / CA_CERT_NAME
    ca_key = TLS_DIR / CA_KEY_NAME
    leaf_crt = TLS_DIR / LEAF_CERT_NAME
    leaf_key = TLS_DIR / LEAF_KEY_NAME
    bundle = TLS_DIR / CA_BUNDLE_NAME

    have_ca = ca_crt.is_file() and ca_key.is_file()
    have_leaf = leaf_crt.is_file() and leaf_key.is_file()
    leaf_ok = have_leaf and _leaf_covers_sans(leaf_crt, sans_dns, sans_ip)

    if force_remint or not have_ca:
        ca_cert_pem, ca_key_pem, leaf_cert_pem, leaf_key_pem = _mint_ca_and_leaf(
            sans_dns, sans_ip
        )
        ca_crt.write_bytes(ca_cert_pem)
        ca_key.write_bytes(ca_key_pem)
        leaf_crt.write_bytes(leaf_cert_pem)
        leaf_key.write_bytes(leaf_key_pem)
        # Local-only material; keep readable so boot.d (root) + start.d agree.
        _relax_key_perms(ca_key, leaf_key)
        LOG.info("gateway TLS minted new CA + leaf")
    elif not leaf_ok:
        ca_cert_pem = ca_crt.read_bytes()
        ca_key_pem = ca_key.read_bytes()
        leaf_cert_pem, leaf_key_pem = _mint_leaf_with_ca(
            ca_cert_pem, ca_key_pem, sans_dns, sans_ip
        )
        leaf_crt.write_bytes(leaf_cert_pem)
        leaf_key.write_bytes(leaf_key_pem)
        _relax_key_perms(ca_key, leaf_key)
        LOG.info("gateway TLS reminted leaf (SANs changed; CA reused)")
    else:
        ca_cert_pem = ca_crt.read_bytes()
        leaf_cert_pem = leaf_crt.read_bytes()
        leaf_key_pem = leaf_key.read_bytes()
        LOG.debug("gateway TLS reusing existing CA + leaf")

    bundle_parts = [_system_ca_bundle_bytes(), ca_cert_pem]
    try:
        bundle.write_bytes(b"".join(p for p in bundle_parts if p))
    except OSError:
        # boot.d often runs as root; start.d as localemu — skip rewrite if owned.
        LOG.debug("ca-bundle rewrite skipped", exc_info=True)

    _install_localemu_server_pem(leaf_cert_pem, leaf_key_pem)
    _chown_tls_tree()
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


def container_ca_paths() -> tuple[str, str]:
    """In-container paths for the CA cert and CA bundle."""
    return f"{TASK_CA_DIR}/{CA_CERT_NAME}", f"{TASK_CA_DIR}/{CA_BUNDLE_NAME}"


def apply_ca_env(env_vars: dict) -> None:
    """Set SDK / runtime CA trust env vars to the in-container mount paths."""
    ca_ctr, bundle_ctr = container_ca_paths()
    env_vars["AWS_CA_BUNDLE"] = bundle_ctr
    env_vars["SSL_CERT_FILE"] = bundle_ctr
    env_vars["NODE_EXTRA_CA_CERTS"] = ca_ctr
    env_vars["REQUESTS_CA_BUNDLE"] = bundle_ctr
    env_vars["CURL_CA_BUNDLE"] = bundle_ctr


def append_no_proxy(env_vars: dict, host: str) -> None:
    """Ensure ``host`` is listed in NO_PROXY / no_proxy."""
    if not host:
        return
    for key in ("NO_PROXY", "no_proxy"):
        cur = env_vars.get(key) or ""
        parts = [p.strip() for p in cur.split(",") if p.strip()]
        if host not in parts:
            parts.append(host)
        env_vars[key] = ",".join(parts)


def apply_https_endpoint(env_vars: dict, *, port: int) -> str:
    """Set ``AWS_ENDPOINT_URL`` to ``https://localemu.awsbox:<port>`` (#687/#696)."""
    env_vars["AWS_ENDPOINT_URL"] = f"https://{EMU_DNS_NAME}:{port}"
    append_no_proxy(env_vars, EMU_DNS_NAME)
    return EMU_DNS_NAME


def _ensure_flag_token(flags: str, needle: str, extra: str) -> str:
    if needle in flags:
        return flags
    return f"{flags} {extra}".strip() if flags else extra


def docker_tls_flags(existing_flags: str, gw_ip: str) -> str:
    """Add ``--add-host`` + ``-v`` CA mounts for Lambda-style additional_flags."""
    flags = (existing_flags or "").strip()
    if not gw_ip:
        return flags
    ca_ctr_src = TLS_DIR / CA_CERT_NAME
    bundle_ctr_src = TLS_DIR / CA_BUNDLE_NAME
    if not ca_ctr_src.is_file() or not bundle_ctr_src.is_file():
        LOG.warning("gateway CA files missing (%s); skip docker TLS flags", ca_ctr_src)
        return _ensure_flag_token(
            flags,
            f"--add-host={EMU_DNS_NAME}:",
            f"--add-host={EMU_DNS_NAME}:{gw_ip}",
        )
    ca_host, bundle_host = task_ca_host_paths()
    if not ca_host or not bundle_host:
        LOG.warning(
            "gateway CA host path unresolved; skip CA volume flags (#696)"
        )
        return _ensure_flag_token(
            flags,
            f"--add-host={EMU_DNS_NAME}:",
            f"--add-host={EMU_DNS_NAME}:{gw_ip}",
        )
    ca_ctr, bundle_ctr = container_ca_paths()
    if (
        f"--add-host={EMU_DNS_NAME}:" not in flags
        and f"--add-host {EMU_DNS_NAME}:" not in flags
    ):
        flags = _ensure_flag_token(
            flags,
            f"--add-host={EMU_DNS_NAME}:",
            f"--add-host={EMU_DNS_NAME}:{gw_ip}",
        )
    flags = _ensure_flag_token(
        flags,
        f"{ca_ctr}:",
        f"-v {ca_host}:{ca_ctr}:ro",
    )
    flags = _ensure_flag_token(
        flags,
        f"{bundle_ctr}:",
        f"-v {bundle_host}:{bundle_ctr}:ro",
    )
    return flags


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

    ca_ctr, bundle_ctr = container_ca_paths()
    volumes.append(BindMount(ca_host, ca_ctr, read_only=True))
    volumes.append(BindMount(bundle_host, bundle_ctr, read_only=True))
    apply_ca_env(env_vars)


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
    dns_out: list[str] = []
    for d in dns:
        if d not in dns_out:
            dns_out.append(d)
    ip_out: list[str] = []
    for ip in ips:
        if ip not in ip_out:
            ip_out.append(ip)
    return dns_out, ip_out


def _leaf_covers_sans(leaf_path: Path, dns_names: list[str], ip_names: list[str]) -> bool:
    try:
        from cryptography import x509

        cert = x509.load_pem_x509_certificate(leaf_path.read_bytes())
        ext = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
        have_dns = {n for n in ext.value.get_values_for_type(x509.DNSName)}
        have_ip = {str(n) for n in ext.value.get_values_for_type(x509.IPAddress)}
    except Exception:
        LOG.debug("leaf SAN parse failed; will remint leaf", exc_info=True)
        return False
    for d in dns_names:
        if d not in have_dns:
            return False
    for ip in ip_names:
        if ip not in have_ip:
            return False
    return True


def _mint_ca_and_leaf(
    dns_names: list[str], ip_names: list[str]
) -> tuple[bytes, bytes, bytes, bytes]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

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

    leaf_cert_pem, leaf_key_pem = _mint_leaf_with_ca(
        ca_cert.public_bytes(serialization.Encoding.PEM),
        ca_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        ),
        dns_names,
        ip_names,
    )
    return (
        ca_cert.public_bytes(serialization.Encoding.PEM),
        ca_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        ),
        leaf_cert_pem,
        leaf_key_pem,
    )


def _mint_leaf_with_ca(
    ca_cert_pem: bytes,
    ca_key_pem: bytes,
    dns_names: list[str],
    ip_names: list[str],
) -> tuple[bytes, bytes]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

    ca_cert = x509.load_pem_x509_certificate(ca_cert_pem)
    ca_key = serialization.load_pem_private_key(ca_key_pem, password=None)
    now = datetime.now(timezone.utc)
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
        .issuer_name(ca_cert.subject)
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
    return (
        leaf_cert.public_bytes(serialization.Encoding.PEM),
        leaf_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        ),
    )


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
    """Overwrite LocalEmu's default combined PEM (+ split .crt/.key).

    Must run before ``_init_gateway_server`` so ``generate_ssl_cert`` sees
    existing files and returns them instead of minting a LocalEmu Org leaf.
    """
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
    _relax_key_perms(Path(f"{target}.key"))


def _relax_key_perms(*paths: Path) -> None:
    for path in paths:
        try:
            path.chmod(0o644)
        except OSError:
            LOG.debug("chmod %s skipped", path, exc_info=True)


def _chown_tls_tree() -> None:
    """boot.d is root; start.d / task mounts need localemu-readable+writable."""
    try:
        import pwd

        ent = pwd.getpwnam("localemu")
    except (KeyError, ImportError, OSError):
        return
    try:
        os.chown(TLS_DIR, ent.pw_uid, ent.pw_gid)
        for path in TLS_DIR.iterdir():
            os.chown(path, ent.pw_uid, ent.pw_gid)
    except OSError:
        LOG.debug("chown tls tree skipped", exc_info=True)


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
