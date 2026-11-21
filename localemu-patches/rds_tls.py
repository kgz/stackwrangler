"""RDS MySQL/MariaDB server TLS with SANs (#765).

MySQL's auto-generated server cert has CN=MySQL_Server_* and no SAN, so
clients that verify the peer name (PHP mysqlnd whenever a CA is set, mysql
``--ssl-mode=VERIFY_IDENTITY``, etc.) fail even with the right CA.

This module:
  * mints a stable local RDS CA under ``/var/lib/awsbox/tls`` (compose
    ``./.awsbox``), published as ``rds-ca.pem`` alongside the gateway CA
  * mints a per-instance leaf covering the Describe endpoint hostname plus
    ``localhost`` / ``127.0.0.1`` for the published host port
  * bind-mounts ca/cert/key into the DB container and injects
    ``--ssl-ca`` / ``--ssl-cert`` / ``--ssl-key`` onto mysqld

Reuse the CA across restarts; remint a leaf only when SANs drift or files
are missing.
"""

from __future__ import annotations

import ipaddress
import logging
import os
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOG = logging.getLogger("localemu.awsbox.rds_tls")

TLS_DIR = Path("/var/lib/awsbox/tls")
RDS_CA_CERT_NAME = "rds-ca.pem"
RDS_CA_KEY_NAME = "rds-ca.key"
INSTANCES_DIRNAME = "rds-instances"
LEAF_CERT_NAME = "server-cert.pem"
LEAF_KEY_NAME = "server-key.pem"
CONTAINER_SSL_DIR = "/etc/mysql/awsbox-ssl"
CONTAINER_CA = f"{CONTAINER_SSL_DIR}/ca.pem"
CONTAINER_CERT = f"{CONTAINER_SSL_DIR}/server-cert.pem"
CONTAINER_KEY = f"{CONTAINER_SSL_DIR}/server-key.pem"

_SSL_FLAGS = (
    f"--ssl-ca={CONTAINER_CA}",
    f"--ssl-cert={CONTAINER_CERT}",
    f"--ssl-key={CONTAINER_KEY}",
)


def ensure_rds_ca(*, force_remint: bool = False) -> Path:
    """Ensure the RDS CA exists and is published under ``.awsbox/tls``."""
    TLS_DIR.mkdir(parents=True, exist_ok=True)
    ca_crt = TLS_DIR / RDS_CA_CERT_NAME
    ca_key = TLS_DIR / RDS_CA_KEY_NAME
    if force_remint or not (ca_crt.is_file() and ca_key.is_file()):
        ca_pem, key_pem = _mint_ca()
        ca_crt.write_bytes(ca_pem)
        ca_key.write_bytes(key_pem)
        _relax_key_perms(ca_key)
        LOG.info("rds TLS minted new CA → %s", ca_crt)
    _chown_tls_tree()
    return ca_crt


def ensure_instance_leaf(
    db_instance_id: str,
    *,
    region: str | None = None,
) -> tuple[Path, Path, Path]:
    """Ensure CA + leaf for ``db_instance_id``; return (ca, cert, key) paths."""
    ensure_rds_ca()
    sans_dns, sans_ip = _san_lists(db_instance_id, region or "us-east-1")
    inst_dir = TLS_DIR / INSTANCES_DIRNAME / _safe_id(db_instance_id)
    inst_dir.mkdir(parents=True, exist_ok=True)
    leaf_crt = inst_dir / LEAF_CERT_NAME
    leaf_key = inst_dir / LEAF_KEY_NAME
    ca_crt = TLS_DIR / RDS_CA_CERT_NAME
    ca_key = TLS_DIR / RDS_CA_KEY_NAME

    have_leaf = leaf_crt.is_file() and leaf_key.is_file()
    if not (have_leaf and _leaf_covers_sans(leaf_crt, sans_dns, sans_ip)):
        leaf_pem, key_pem = _mint_leaf_with_ca(
            ca_crt.read_bytes(),
            ca_key.read_bytes(),
            sans_dns,
            sans_ip,
            common_name=sans_dns[0] if sans_dns else "localhost",
        )
        leaf_crt.write_bytes(leaf_pem)
        leaf_key.write_bytes(key_pem)
        _relax_key_perms(leaf_key)
        LOG.info(
            "rds TLS leaf for %s dns=%s ips=%s",
            db_instance_id,
            ",".join(sans_dns),
            ",".join(sans_ip),
        )
    _chown_tls_tree()
    return ca_crt, leaf_crt, leaf_key


def apply_mysql_tls(container_config, db_instance_id: str) -> bool:
    """Bind-mount certs and inject mysqld SSL flags. Returns True if applied."""
    from localemu.utils.container_utils.container_client import BindMount

    region = os.environ.get("DEFAULT_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
    try:
        ca_path, cert_path, key_path = ensure_instance_leaf(
            db_instance_id, region=region
        )
    except Exception:
        LOG.exception("rds TLS mint failed for %s", db_instance_id)
        return False

    ca_host = _resolve_host_bind(str(ca_path))
    cert_host = _resolve_host_bind(str(cert_path))
    key_host = _resolve_host_bind(str(key_path))
    if not ca_host or not cert_host or not key_host:
        LOG.warning(
            "rds TLS host bind paths unresolved for %s (ca=%s cert=%s key=%s)",
            db_instance_id,
            ca_host,
            cert_host,
            key_host,
        )
        return False

    volumes = getattr(container_config, "volumes", None)
    if volumes is None:
        return False
    volumes.add(BindMount(ca_host, CONTAINER_CA, read_only=True))
    volumes.add(BindMount(cert_host, CONTAINER_CERT, read_only=True))
    volumes.add(BindMount(key_host, CONTAINER_KEY, read_only=True))

    before = getattr(container_config, "command", None)
    container_config.command = _inject_ssl_flags(before)
    LOG.info(
        "rds TLS applied to %s cmd=%s",
        db_instance_id,
        container_config.command,
    )
    return True


def published_ca_host_path() -> str | None:
    """Docker-host path for ``rds-ca.pem`` (apps / smokes)."""
    ensure_rds_ca()
    return _resolve_host_bind(str(TLS_DIR / RDS_CA_CERT_NAME))


def is_mysql_family(engine: str) -> bool:
    e = (engine or "").lower()
    return e in ("mysql", "mariadb") or e.startswith("aurora-mysql")


def _safe_id(db_instance_id: str) -> str:
    return re.sub(r"[^A-Za-z0-9._-]+", "_", db_instance_id)[:128] or "db"


def _endpoint_hostname(db_instance_id: str, region: str) -> str:
    try:
        from localemu.services.rds.provider import _rds_endpoint_address

        host = _rds_endpoint_address(db_instance_id, region)
        if isinstance(host, str) and host.strip():
            return host.strip()
    except Exception:
        LOG.debug("rds endpoint address lookup failed", exc_info=True)
    return "localhost"


def _san_lists(db_instance_id: str, region: str) -> tuple[list[str], list[str]]:
    endpoint = _endpoint_hostname(db_instance_id, region)
    dns: list[str] = []
    for name in (endpoint, "localhost"):
        if name and name not in dns and not _looks_like_ip(name):
            dns.append(name)
    ips: list[str] = ["127.0.0.1"]
    if _looks_like_ip(endpoint) and endpoint not in ips:
        ips.append(endpoint)
    return dns, ips


def _looks_like_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def _inject_ssl_flags(command: list[str] | None) -> list[str]:
    flags = list(_SSL_FLAGS)
    if command is None:
        return ["mysqld", *flags]
    if command and command[0] == "mysqld":
        # Avoid duplicating if create is retried / double-wrapped.
        existing = set(command)
        extra = [f for f in flags if f not in existing]
        return [*command, *extra] if extra else list(command)
    if (
        command
        and command[0] == "bash"
        and len(command) >= 3
        and isinstance(command[2], str)
    ):
        return ["bash", "-c", _inject_mysql_reader_flags(command[2], flags)]
    # Unknown CMD shape — still prefer mysqld with SSL over silent skip.
    return ["mysqld", *flags, *command]


def _inject_mysql_reader_flags(script: str, flags: list[str]) -> str:
    if not flags:
        return script
    if any(f in script for f in flags):
        return script
    flag_str = " " + " ".join(flags)
    replaced, n = re.subn(
        r"(docker-entrypoint\.sh mysqld)",
        rf"\1{flag_str}",
        script,
        count=1,
    )
    if n:
        return replaced
    replaced, n = re.subn(
        r"(^mysqld)\b",
        rf"\1{flag_str}",
        script,
        count=1,
        flags=re.M,
    )
    return replaced if n else script


def _leaf_covers_sans(leaf_path: Path, dns_names: list[str], ip_names: list[str]) -> bool:
    try:
        from cryptography import x509

        cert = x509.load_pem_x509_certificate(leaf_path.read_bytes())
        ext = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
        have_dns = {n for n in ext.value.get_values_for_type(x509.DNSName)}
        have_ip = {str(n) for n in ext.value.get_values_for_type(x509.IPAddress)}
    except Exception:
        LOG.debug("rds leaf SAN parse failed; will remint", exc_info=True)
        return False
    for d in dns_names:
        if d not in have_dns:
            return False
    for ip in ip_names:
        if ip not in have_ip:
            return False
    return True


def _mint_ca() -> tuple[bytes, bytes]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID

    now = datetime.now(timezone.utc)
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    ca_name = x509.Name(
        [
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "stackwrangler"),
            x509.NameAttribute(NameOID.COMMON_NAME, "stackwrangler RDS CA"),
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
    return (
        ca_cert.public_bytes(serialization.Encoding.PEM),
        ca_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.TraditionalOpenSSL,
            encryption_algorithm=serialization.NoEncryption(),
        ),
    )


def _mint_leaf_with_ca(
    ca_cert_pem: bytes,
    ca_key_pem: bytes,
    dns_names: list[str],
    ip_names: list[str],
    *,
    common_name: str,
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
            x509.NameAttribute(NameOID.COMMON_NAME, common_name[:64]),
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


def _relax_key_perms(*paths: Path) -> None:
    for path in paths:
        try:
            path.chmod(0o644)
        except OSError:
            LOG.debug("chmod %s skipped", path, exc_info=True)


def _chown_tls_tree() -> None:
    try:
        import pwd

        ent = pwd.getpwnam("localemu")
    except (KeyError, ImportError, OSError):
        return
    try:
        os.chown(TLS_DIR, ent.pw_uid, ent.pw_gid)
        for path in TLS_DIR.rglob("*"):
            try:
                os.chown(path, ent.pw_uid, ent.pw_gid)
            except OSError:
                pass
    except OSError:
        LOG.debug("chown rds tls tree skipped", exc_info=True)


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
