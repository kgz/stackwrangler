"""Transfer Family inbound SFTP with service-managed SSH public keys (#141).

Starts a paramiko SFTP listener inside LocalEmu. Auth is public-key only against
moto Transfer users (ImportSshPublicKey / CreateUser SshPublicKeyBody). Password
auth is rejected. Uploads land in the user's PATH home on LocalEmu S3 under the
user's Transfer role (IAM enforced via gateway AssumeRole).

Host port: compose publishes AWSBOX_SFTP_HOST_PORT → AWSBOX_TRANSFER_SFTP_PORT
(default 2222). Endpoint string is attached on DescribeServer when ONLINE.
"""

from __future__ import annotations

import importlib.util
import io
import json
import logging
import os
import posixpath
import socket
import threading
import time

LOG = logging.getLogger("localemu.awsbox.transfer_sftp")

_SERVICE = "transfer.amazonaws.com"
_HOST_KEY = None
_LISTEN_PORT = int(os.environ.get("AWSBOX_TRANSFER_SFTP_PORT") or "2222")
_ENDPOINT_HOST = (os.environ.get("AWSBOX_TRANSFER_SFTP_HOST") or "127.0.0.1").strip()


def _paramiko():
    spec = importlib.util.spec_from_file_location(
        "awsbox_paramiko_vendor", "/opt/awsbox/paramiko_vendor.py"
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("paramiko_vendor missing at /opt/awsbox/paramiko_vendor.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.ensure_paramiko()


def _host_key():
    global _HOST_KEY
    if _HOST_KEY is not None:
        return _HOST_KEY
    paramiko = _paramiko()
    key_path = os.environ.get("AWSBOX_TRANSFER_HOST_KEY") or "/tmp/awsbox-transfer-host-key"
    if os.path.isfile(key_path):
        _HOST_KEY = paramiko.RSAKey.from_private_key_file(key_path)
    else:
        _HOST_KEY = paramiko.RSAKey.generate(2048)
        try:
            _HOST_KEY.write_private_key_file(key_path)
        except OSError:
            pass
    return _HOST_KEY


def _iter_users():
    from moto.transfer.models import transfer_backends

    for account_id, regions in transfer_backends.items():
        for region, backend in regions.items():
            for server_id, server in backend.servers.items():
                protocols = server.protocols or []
                proto_names = [
                    getattr(p, "value", p) if not isinstance(p, str) else p for p in protocols
                ]
                if proto_names and "SFTP" not in proto_names:
                    continue
                for user in server._users:
                    yield account_id, region, server_id, server, user


def _find_user(username: str):
    matches = [row for row in _iter_users() if row[4].user_name == username]
    if not matches:
        return None
    # Prefer the newest server when names collide (local single-endpoint model).
    return matches[-1]


def _key_matches(user, presented) -> bool:
    body = f"{presented.get_name()} {presented.get_base64()}"
    for key in user.ssh_public_keys or []:
        stored = (key.get("ssh_public_key_body") or "").strip()
        if not stored:
            continue
        parts = stored.split()
        if len(parts) >= 2 and f"{parts[0]} {parts[1]}" == body:
            return True
        if stored == body or stored.startswith(body):
            return True
    return False


def _parse_home(home: str | None) -> tuple[str, str]:
    """Return (bucket, key_prefix) for PATH home `/bucket` or `/bucket/prefix`."""
    trimmed = (home or "").strip().strip("/")
    if not trimmed:
        raise ValueError("Transfer user has no HomeDirectory")
    bucket, _, prefix = trimmed.partition("/")
    if not bucket:
        raise ValueError(f"Invalid HomeDirectory: {home}")
    return bucket, prefix.strip("/")


def _as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def _glob_match(pattern: str, value: str) -> bool:
    import re

    regex = "".join(
        ".*" if ch == "*" else "." if ch == "?" else re.escape(ch) for ch in pattern
    )
    return re.fullmatch(regex, value) is not None


def _condition_holds(condition: dict, facts: dict[str, str]) -> bool:
    for operator, pairs in (condition or {}).items():
        op = operator.lower().removesuffix("ifexists")
        for key, wanted in (pairs or {}).items():
            actual = facts.get(key.lower())
            if actual is None:
                return False
            wanted_list = wanted if isinstance(wanted, list) else [wanted]
            if op in ("stringequals", "arnequals"):
                hit = actual in wanted_list
            elif op in ("stringlike", "arnlike"):
                hit = any(_glob_match(str(w), actual) for w in wanted_list)
            else:
                return False
            if not hit:
                return False
    return True


def _trust_allows_transfer(trust_doc, account: str, server_arn: str) -> bool:
    doc = json.loads(trust_doc) if isinstance(trust_doc, str) else (trust_doc or {})
    if not isinstance(doc, dict):
        return False
    facts = {"aws:sourceaccount": account, "aws:sourcearn": server_arn}
    allowed = False
    for stmt in _as_list(doc.get("Statement")):
        if not isinstance(stmt, dict):
            continue
        principal = stmt.get("Principal") or {}
        services = _as_list(principal.get("Service")) if isinstance(principal, dict) else []
        actions = [str(a).lower() for a in _as_list(stmt.get("Action"))]
        if _SERVICE not in services:
            continue
        if not any(a in ("sts:assumerole", "sts:*", "*") for a in actions):
            continue
        if not _condition_holds(stmt.get("Condition") or {}, facts):
            continue
        if stmt.get("Effect") == "Deny":
            return False
        if stmt.get("Effect") == "Allow":
            allowed = True
    return allowed


def _s3_client(account: str, region: str, role_arn: str, server_id: str):
    import boto3
    from botocore.config import Config as BotoConfig
    from localemu import config as le_config
    from moto.iam.models import iam_backends
    from moto.sts.models import sts_backends

    role_name = role_arn.rsplit("/", 1)[-1]
    role_account = role_arn.split(":")[4] if role_arn.count(":") >= 5 else account
    try:
        role = iam_backends[role_account]["global"].get_role(role_name)
    except Exception as exc:
        raise PermissionError(f"Transfer role {role_arn} not found: {exc}") from exc
    server_arn = f"arn:aws:transfer:{region}:{account}:server/{server_id}"
    if not _trust_allows_transfer(
        getattr(role, "assume_role_policy_document", None), account, server_arn
    ):
        raise PermissionError(
            f"Role {role_arn} does not trust {_SERVICE} for {server_arn}"
        )
    assumed = sts_backends[role_account]["global"].assume_role(
        region_name=region,
        role_session_name=f"transfer-sftp-{server_id}"[:64],
        role_arn=role_arn,
        policy=None,
        duration=3600,
        external_id=None,
    )
    return boto3.client(
        "s3",
        region_name=region,
        endpoint_url=f"http://127.0.0.1:{le_config.GATEWAY_LISTEN[0].port}",
        aws_access_key_id=assumed.access_key_id,
        aws_secret_access_key=assumed.secret_access_key,
        aws_session_token=assumed.session_token,
        config=BotoConfig(
            retries={"max_attempts": 1, "mode": "standard"},
            connect_timeout=5,
            read_timeout=30,
            s3={"addressing_style": "path"},
        ),
    )


def _object_key(prefix: str, rel: str) -> str:
    rel = rel.lstrip("/")
    if not prefix:
        return rel
    if not rel:
        return prefix
    return f"{prefix}/{rel}"


class _TransferSession:
    def __init__(self, account, region, server_id, user):
        self.account = account
        self.region = region
        self.server_id = server_id
        self.user = user
        self.bucket, self.prefix = _parse_home(user.home_directory)
        self._s3 = None

    def s3(self):
        if self._s3 is None:
            self._s3 = _s3_client(
                self.account, self.region, self.user.role, self.server_id
            )
        return self._s3


def _make_server_interface(paramiko):
    class TransferAuth(paramiko.ServerInterface):
        def __init__(self):
            self.session = None

        def check_channel_request(self, kind, chanid):
            if kind == "session":
                return paramiko.OPEN_SUCCEEDED
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

        def get_allowed_auths(self, username):
            return "publickey"

        def check_auth_password(self, username, password):
            return paramiko.AUTH_FAILED

        def check_auth_publickey(self, username, key):
            found = _find_user(username)
            if found is None:
                return paramiko.AUTH_FAILED
            account, region, server_id, _server, user = found
            if not _key_matches(user, key):
                return paramiko.AUTH_FAILED
            try:
                self.session = _TransferSession(account, region, server_id, user)
            except Exception as exc:
                LOG.warning("transfer sftp home parse failed for %s: %s", username, exc)
                return paramiko.AUTH_FAILED
            return paramiko.AUTH_SUCCESSFUL

        # Do not override check_channel_subsystem_request — the default starts
        # the handler registered via Transport.set_subsystem_handler.

    return TransferAuth


def _make_sftp_interface(paramiko):
    class S3Handle(paramiko.SFTPHandle):
        def __init__(self, session: _TransferSession, key: str, writing: bool):
            super().__init__()
            self._session = session
            self._key = key
            self._writing = writing
            self._buf = io.BytesIO()
            self._read_buf = None
            self._read_off = 0

        def write(self, offset, data):
            if not self._writing:
                return paramiko.SFTP_PERMISSION_DENIED
            self._buf.seek(offset)
            self._buf.write(data)
            return paramiko.SFTP_OK

        def read(self, offset, length):
            if self._writing:
                return paramiko.SFTP_PERMISSION_DENIED
            if self._read_buf is None:
                try:
                    body = self._session.s3().get_object(
                        Bucket=self._session.bucket, Key=self._key
                    )["Body"].read()
                except Exception as exc:
                    LOG.info("sftp get %s: %s", self._key, exc)
                    return paramiko.SFTP_NO_SUCH_FILE
                self._read_buf = body
            if offset >= len(self._read_buf):
                return b""
            return self._read_buf[offset : offset + length]

        def close(self):
            if self._writing:
                data = self._buf.getvalue()
                try:
                    self._session.s3().put_object(
                        Bucket=self._session.bucket, Key=self._key, Body=data
                    )
                except Exception as exc:
                    LOG.warning(
                        "sftp put s3://%s/%s failed: %s",
                        self._session.bucket,
                        self._key,
                        exc,
                    )
                    return paramiko.SFTP_FAILURE
            return super().close()

    class TransferFS(paramiko.SFTPServerInterface):
        def __init__(self, server, *args, **kwargs):
            super().__init__(server, *args, **kwargs)
            self.session = getattr(server, "session", None)

        def _rel(self, path: str) -> str:
            path = posixpath.normpath(path or "/")
            if path in (".", "/"):
                return ""
            return path.lstrip("/")

        def list_folder(self, path):
            if self.session is None:
                return paramiko.SFTP_FAILURE
            rel = self._rel(path)
            prefix = _object_key(self.session.prefix, rel)
            if prefix and not prefix.endswith("/"):
                prefix = prefix + "/"
            try:
                paginator = self.session.s3().get_paginator("list_objects_v2")
                names = []
                seen_dirs = set()
                for page in paginator.paginate(
                    Bucket=self.session.bucket, Prefix=prefix, Delimiter="/"
                ):
                    for obj in page.get("Contents") or []:
                        key = obj["Key"]
                        name = key[len(prefix) :] if prefix else key
                        if not name or "/" in name.rstrip("/"):
                            continue
                        attr = paramiko.SFTPAttributes()
                        attr.filename = name
                        attr.st_mode = 0o100644
                        attr.st_size = int(obj.get("Size") or 0)
                        names.append(attr)
                    for cp in page.get("CommonPrefixes") or []:
                        p = cp.get("Prefix") or ""
                        name = p[len(prefix) :] if prefix else p
                        name = name.strip("/")
                        if not name or name in seen_dirs:
                            continue
                        seen_dirs.add(name)
                        attr = paramiko.SFTPAttributes()
                        attr.filename = name
                        attr.st_mode = 0o040755
                        attr.st_size = 0
                        names.append(attr)
                return names
            except Exception as exc:
                LOG.info("sftp list failed: %s", exc)
                return paramiko.SFTP_FAILURE

        def stat(self, path):
            return self.lstat(path)

        def lstat(self, path):
            if self.session is None:
                return paramiko.SFTP_FAILURE
            rel = self._rel(path)
            if rel == "":
                attr = paramiko.SFTPAttributes()
                attr.filename = "/"
                attr.st_mode = 0o040755
                attr.st_size = 0
                return attr
            key = _object_key(self.session.prefix, rel)
            try:
                head = self.session.s3().head_object(
                    Bucket=self.session.bucket, Key=key
                )
                attr = paramiko.SFTPAttributes()
                attr.filename = posixpath.basename(rel)
                attr.st_mode = 0o100644
                attr.st_size = int(head.get("ContentLength") or 0)
                return attr
            except Exception:
                # Directory if any child exists.
                prefix = key if key.endswith("/") else key + "/"
                try:
                    out = self.session.s3().list_objects_v2(
                        Bucket=self.session.bucket, Prefix=prefix, MaxKeys=1
                    )
                    if out.get("KeyCount"):
                        attr = paramiko.SFTPAttributes()
                        attr.filename = posixpath.basename(rel)
                        attr.st_mode = 0o040755
                        attr.st_size = 0
                        return attr
                except Exception:
                    pass
                return paramiko.SFTP_NO_SUCH_FILE

        def open(self, path, flags, attr):
            if self.session is None:
                return paramiko.SFTP_FAILURE
            rel = self._rel(path)
            if not rel or rel.endswith("/"):
                return paramiko.SFTP_FAILURE
            key = _object_key(self.session.prefix, rel)
            writing = bool(flags & (os.O_WRONLY | os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_TRUNC))
            return S3Handle(self.session, key, writing)

        def remove(self, path):
            if self.session is None:
                return paramiko.SFTP_FAILURE
            key = _object_key(self.session.prefix, self._rel(path))
            try:
                self.session.s3().delete_object(Bucket=self.session.bucket, Key=key)
                return paramiko.SFTP_OK
            except Exception:
                return paramiko.SFTP_FAILURE

        def mkdir(self, path, attr):
            # S3 has no real dirs; accept for clients that mkdir before put.
            return paramiko.SFTP_OK

        def rmdir(self, path):
            return paramiko.SFTP_OK

    return TransferFS


def _handle_client(client, addr):
    paramiko = _paramiko()
    Auth = _make_server_interface(paramiko)
    FS = _make_sftp_interface(paramiko)
    transport = None
    try:
        transport = paramiko.Transport(client)
        transport.add_server_key(_host_key())
        transport.set_subsystem_handler("sftp", paramiko.SFTPServer, FS)
        server = Auth()
        transport.start_server(server=server)
        channel = transport.accept(20)
        if channel is None:
            return
        # Keep the transport alive while the SFTP subsystem runs.
        while transport.is_active():
            time.sleep(0.2)
    except Exception as exc:
        LOG.info("transfer sftp client %s closed: %s", addr, exc)
    finally:
        try:
            if transport is not None:
                transport.close()
        except Exception:
            pass
        try:
            client.close()
        except Exception:
            pass


def _serve():
    paramiko = _paramiko()
    _ = paramiko  # ensure import before accept loop
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", _LISTEN_PORT))
    sock.listen(50)
    LOG.info(
        "awsbox Transfer SFTP listening on 0.0.0.0:%s (host %s:%s)",
        _LISTEN_PORT,
        _ENDPOINT_HOST,
        os.environ.get("AWSBOX_SFTP_HOST_PORT") or _LISTEN_PORT,
    )
    while True:
        try:
            client, addr = sock.accept()
        except OSError:
            break
        threading.Thread(
            target=_handle_client,
            args=(client, addr),
            daemon=True,
            name=f"xfer-sftp-{addr[1]}",
        ).start()


def _patch_describe_endpoint() -> None:
    """Expose a usable Endpoint on DescribeServer (moto omits public DNS)."""
    try:
        from moto.transfer import types as transfer_types
    except Exception as exc:
        LOG.warning("could not patch Transfer Endpoint: %s", exc)
        return

    host_port = os.environ.get("AWSBOX_SFTP_HOST_PORT") or str(_LISTEN_PORT)
    endpoint = f"{_ENDPOINT_HOST}:{host_port}"
    original = transfer_types.Server.to_dict

    def to_dict(self):
        out = original(self)
        out["Endpoint"] = endpoint
        state = out.get("State")
        state_val = getattr(state, "value", state)
        if not state_val or state_val == "OFFLINE":
            out["State"] = "ONLINE"
        return out

    transfer_types.Server.to_dict = to_dict
    LOG.info("DescribeServer Endpoint → %s", endpoint)


def _install() -> None:
    _patch_describe_endpoint()
    threading.Thread(target=_prewarm_and_serve, daemon=True, name="transfer-sftp").start()


def _prewarm_and_serve() -> None:
    try:
        _paramiko()
        _host_key()
    except Exception as exc:
        LOG.warning("transfer sftp prewarm failed: %s", exc)
        return
    try:
        _serve()
    except Exception:
        LOG.exception("transfer sftp listener crashed")


_install()
