"""Transfer Family outbound SFTP connectors (#295).

moto's Transfer backend only knows servers and users. This hook adds the
connector control plane (Create/Describe/Update/Delete/ListConnectors,
TestConnection) and an SFTP data plane for StartFileTransfer:

* The access role is assumed through the gateway, so its S3 and Secrets Manager
  (plus implicit KMS decrypt) permissions are evaluated like a real caller's.
* The role trust policy must allow transfer.amazonaws.com for this connector
  (aws:SourceAccount / aws:SourceArn), otherwise the transfer fails.
* Transfers run in the background; results are read with ListFileTransferResults.
* With a LoggingRole, events land in CloudWatch Logs group /aws/transfer/<connector-id>.

The SFTP client (paramiko) is pip-installed into the LocalEmu venv on first use.
"""

from __future__ import annotations

import io
import json
import logging
import posixpath
import re
import secrets
import subprocess
import sys
import threading
import time

LOG = logging.getLogger("localemu.awsbox.transfer_connectors")

_LOCK = threading.RLock()
_CONNECTORS: dict[tuple[str, str], dict[str, dict]] = {}
_TRANSFERS: dict[str, dict] = {}
_PARAMIKO_LOCK = threading.Lock()
_SERVICE = "transfer.amazonaws.com"


class _TransferFailure(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def _error(code: str, message: str, status: int = 400):
    from localemu.aws.api import CommonServiceException

    return CommonServiceException(
        code=code, message=message, status_code=status, sender_fault=True
    )


def _paramiko():
    try:
        import paramiko

        return paramiko
    except ImportError:
        pass
    with _PARAMIKO_LOCK:
        try:
            import paramiko

            return paramiko
        except ImportError:
            pass
        proc = subprocess.run(
            [sys.executable, "-m", "pip", "install", "--quiet", "paramiko"],
            capture_output=True,
            text=True,
            timeout=300,
        )
        if proc.returncode != 0:
            raise _TransferFailure(
                "SFTP_CLIENT_UNAVAILABLE",
                "paramiko could not be installed in LocalEmu: " + proc.stderr.strip()[-300:],
            )
        import paramiko

        return paramiko


def _connectors(account: str, region: str) -> dict[str, dict]:
    with _LOCK:
        return _CONNECTORS.setdefault((account, region), {})


def _connector_arn(account: str, region: str, connector_id: str) -> str:
    return f"arn:aws:transfer:{region}:{account}:connector/{connector_id}"


def _get_connector(context, request) -> dict:
    connector_id = request.get("ConnectorId")
    found = _connectors(context.account_id, context.region).get(connector_id or "")
    if found is None:
        raise _error("ResourceNotFoundException", f"Unknown connector: {connector_id}")
    return found


def _parse_sftp_url(url: str) -> tuple[str, int]:
    match = re.fullmatch(r"sftp://([^/:\s]+)(?::(\d{1,5}))?/?", url or "")
    if not match:
        raise _error(
            "InvalidRequestException",
            "Url must look like sftp://host[:port] for an SFTP connector",
        )
    return match.group(1), int(match.group(2) or 22)


def _validate_config(request: dict, existing: dict | None = None) -> None:
    url = request.get("Url", (existing or {}).get("Url"))
    as2 = request.get("As2Config", (existing or {}).get("As2Config"))
    if as2:
        return
    _parse_sftp_url(url)
    sftp = request.get("SftpConfig") or {}
    for key in sftp.get("TrustedHostKeys") or []:
        if len(key.split()) < 2:
            raise _error(
                "InvalidRequestException",
                "TrustedHostKeys entries look like '<key-type> <base64>' (ssh-keyscan output)",
            )


def _described(connector: dict) -> dict:
    out = {
        key: connector[key]
        for key in (
            "Arn",
            "ConnectorId",
            "Url",
            "As2Config",
            "AccessRole",
            "LoggingRole",
            "SftpConfig",
            "SecurityPolicyName",
        )
        if connector.get(key) is not None
    }
    out["Tags"] = connector.get("Tags") or []
    out["ServiceManagedEgressIpAddresses"] = []
    out["EgressType"] = "SERVICE_MANAGED"
    out["Status"] = "ACTIVE"
    return out


def create_connector(context, request):
    _validate_config(request)
    account, region = context.account_id, context.region
    connector_id = "c-" + secrets.token_hex(9)
    connector = {
        key: request[key]
        for key in (
            "Url",
            "As2Config",
            "AccessRole",
            "LoggingRole",
            "Tags",
            "SftpConfig",
            "SecurityPolicyName",
        )
        if request.get(key) is not None
    }
    connector["ConnectorId"] = connector_id
    connector["Arn"] = _connector_arn(account, region, connector_id)
    with _LOCK:
        _connectors(account, region)[connector_id] = connector
    return {"ConnectorId": connector_id}


def describe_connector(context, request):
    return {"Connector": _described(_get_connector(context, request))}


def update_connector(context, request):
    connector = _get_connector(context, request)
    _validate_config(request, connector)
    with _LOCK:
        for key in (
            "Url",
            "As2Config",
            "AccessRole",
            "LoggingRole",
            "SftpConfig",
            "SecurityPolicyName",
        ):
            if request.get(key) is not None:
                connector[key] = request[key]
    return {"ConnectorId": connector["ConnectorId"]}


def delete_connector(context, request):
    connector = _get_connector(context, request)
    with _LOCK:
        _connectors(context.account_id, context.region).pop(connector["ConnectorId"], None)
    return {}


def list_connectors(context, request):
    with _LOCK:
        items = list(_connectors(context.account_id, context.region).values())
    return {
        "Connectors": [
            {"Arn": c["Arn"], "ConnectorId": c["ConnectorId"], "Url": c.get("Url", "")}
            for c in items
        ]
    }


# ---- access role: trust + credentials --------------------------------------


def _glob_match(pattern: str, value: str) -> bool:
    regex = "".join(
        ".*" if ch == "*" else "." if ch == "?" else re.escape(ch) for ch in pattern
    )
    return re.fullmatch(regex, value) is not None


def _condition_holds(condition: dict, facts: dict[str, str]) -> bool:
    for operator, pairs in (condition or {}).items():
        op = operator.lower().removesuffix("ifexists")
        for key, wanted in pairs.items():
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


def _as_list(value) -> list:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def _trust_allows_transfer(trust_doc, account: str, connector_arn: str) -> bool:
    doc = json.loads(trust_doc) if isinstance(trust_doc, str) else (trust_doc or {})
    facts = {"aws:sourceaccount": account, "aws:sourcearn": connector_arn}
    allowed = False
    for stmt in _as_list(doc.get("Statement")):
        principal = stmt.get("Principal") or {}
        services = _as_list(principal.get("Service")) if isinstance(principal, dict) else []
        actions = [a.lower() for a in _as_list(stmt.get("Action"))]
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


def _role_clients(connector: dict, role_arn: str, account: str, region: str, services):
    """boto3 clients signed as the role through the gateway (IAM enforced)."""
    import boto3
    from botocore.config import Config as BotoConfig
    from localemu import config as le_config
    from moto.iam.models import iam_backends
    from moto.sts.models import sts_backends

    role_name = role_arn.rsplit("/", 1)[-1]
    role_account = role_arn.split(":")[4] if role_arn.count(":") >= 5 else account
    try:
        role = iam_backends[role_account]["global"].get_role(role_name)
    except Exception:
        raise _TransferFailure("ACCESS_ROLE_NOT_FOUND", f"Access role {role_arn} does not exist")
    if not _trust_allows_transfer(
        getattr(role, "assume_role_policy_document", None), account, connector["Arn"]
    ):
        raise _TransferFailure(
            "ACCESS_ROLE_TRUST",
            f"Role {role_arn} does not trust {_SERVICE} for {connector['Arn']} "
            "(check aws:SourceAccount / aws:SourceArn in the trust policy)",
        )
    assumed = sts_backends[role_account]["global"].assume_role(
        region_name=region,
        role_session_name=f"transfer-{connector['ConnectorId']}"[:64],
        role_arn=role_arn,
        policy=None,
        duration=3600,
        external_id=None,
    )
    common = {
        "region_name": region,
        "endpoint_url": f"http://127.0.0.1:{le_config.GATEWAY_LISTEN[0].port}",
        "aws_access_key_id": assumed.access_key_id,
        "aws_secret_access_key": assumed.secret_access_key,
        "aws_session_token": assumed.session_token,
        "config": BotoConfig(
            retries={"max_attempts": 1, "mode": "standard"},
            connect_timeout=5,
            read_timeout=20,
        ),
    }
    return {name: boto3.client(name, **common) for name in services}


def _client_error_text(exc: Exception) -> tuple[str, str]:
    response = getattr(exc, "response", None)
    if isinstance(response, dict):
        err = response.get("Error") or {}
        return str(err.get("Code") or "Error"), str(err.get("Message") or exc)
    return type(exc).__name__, str(exc)


def _denied(code: str) -> bool:
    return code in ("AccessDenied", "AccessDeniedException", "403", "Forbidden")


# ---- SFTP ------------------------------------------------------------------


def _host_key_string(key) -> str:
    return f"{key.get_name()} {key.get_base64()}"


def _load_private_key(paramiko, text: str, passphrase):
    for cls in (paramiko.RSAKey, paramiko.Ed25519Key, paramiko.ECDSAKey):
        try:
            return cls.from_private_key(io.StringIO(text), password=passphrase)
        except Exception:
            continue
    raise _TransferFailure("SECRET_INVALID", "PrivateKey in the user secret is not a supported key")


def _read_user_secret(clients, connector: dict) -> dict:
    secret_id = (connector.get("SftpConfig") or {}).get("UserSecretId")
    if not secret_id:
        raise _TransferFailure("SECRET_MISSING", "Connector has no SftpConfig.UserSecretId")
    try:
        raw = clients["secretsmanager"].get_secret_value(SecretId=secret_id)["SecretString"]
    except Exception as exc:
        code, message = _client_error_text(exc)
        raise _TransferFailure(
            "ACCESS_DENIED_SECRET" if _denied(code) else "SECRET_ERROR",
            f"Reading secret {secret_id}: {code}: {message}",
        )
    try:
        secret = json.loads(raw)
        username = secret["Username"]
    except Exception:
        raise _TransferFailure(
            "SECRET_INVALID", 'User secret must be JSON with "Username" and "Password" or "PrivateKey"'
        )
    if not (secret.get("Password") or secret.get("PrivateKey")):
        raise _TransferFailure("SECRET_INVALID", 'User secret needs "Password" or "PrivateKey"')
    return {"Username": username, **secret}


def _open_sftp(connector: dict, secret: dict):
    """Returns (transport, sftp, host_key). Raises _TransferFailure."""
    import socket

    paramiko = _paramiko()
    host, port = _parse_sftp_url(connector.get("Url", ""))
    try:
        sock = socket.create_connection((host, port), timeout=10)
    except OSError as exc:
        raise _TransferFailure("CONNECTION_ERROR", f"Cannot reach {host}:{port}: {exc}")
    transport = paramiko.Transport(sock)
    try:
        transport.start_client(timeout=15)
        host_key = _host_key_string(transport.get_remote_server_key())
        trusted = [
            " ".join(k.split()[:2])
            for k in (connector.get("SftpConfig") or {}).get("TrustedHostKeys") or []
        ]
        if host_key not in trusted:
            exc = _TransferFailure(
                "HOST_KEY_NOT_TRUSTED",
                f"Host key of {host}:{port} is not in SftpConfig.TrustedHostKeys",
            )
            exc.host_key = host_key
            raise exc
        if secret is not None:
            if secret.get("PrivateKey"):
                pkey = _load_private_key(paramiko, secret["PrivateKey"], secret.get("Passphrase"))
                transport.auth_publickey(secret["Username"], pkey)
            else:
                transport.auth_password(secret["Username"], secret["Password"])
        sftp = paramiko.SFTPClient.from_transport(transport)
        return transport, sftp, host_key
    except _TransferFailure:
        transport.close()
        raise
    except paramiko.AuthenticationException as exc:
        transport.close()
        raise _TransferFailure("SFTP_AUTH_FAILED", f"SFTP login rejected for {secret['Username']}: {exc}")
    except Exception as exc:
        transport.close()
        raise _TransferFailure("CONNECTION_ERROR", f"SFTP session to {host}:{port} failed: {exc}")


def test_connection(context, request):
    connector = _get_connector(context, request)
    connector_id = connector["ConnectorId"]
    result = {"ConnectorId": connector_id}
    if connector.get("As2Config"):
        return {**result, "Status": "ERROR", "StatusMessage": "AS2 connectors are not supported"}
    try:
        clients = _role_clients(
            connector, connector["AccessRole"], context.account_id, context.region, ["secretsmanager"]
        )
        secret = _read_user_secret(clients, connector)
        transport, sftp, host_key = _open_sftp(connector, secret)
        sftp.close()
        transport.close()
    except _TransferFailure as exc:
        out = {**result, "Status": "ERROR", "StatusMessage": f"{exc.code}: {exc.message}"}
        if getattr(exc, "host_key", None):
            out["SftpConnectionDetails"] = {"HostKey": exc.host_key}
        return out
    return {
        **result,
        "Status": "OK",
        "StatusMessage": "Connection succeeded",
        "SftpConnectionDetails": {"HostKey": host_key},
    }


# ---- StartFileTransfer -----------------------------------------------------


def _log_event(connector: dict, clients, transfer_id: str, **fields) -> None:
    if not clients:
        return
    group = f"/aws/transfer/{connector['ConnectorId']}"
    logs = clients["logs"]
    try:
        for create in (
            lambda: logs.create_log_group(logGroupName=group),
            lambda: logs.create_log_stream(logGroupName=group, logStreamName=transfer_id),
        ):
            try:
                create()
            except Exception as exc:
                if _client_error_text(exc)[0] != "ResourceAlreadyExistsException":
                    raise
        message = json.dumps(
            {"connector-id": connector["ConnectorId"], "transfer-id": transfer_id, **fields}
        )
        logs.put_log_events(
            logGroupName=group,
            logStreamName=transfer_id,
            logEvents=[{"timestamp": int(time.time() * 1000), "message": message}],
        )
    except Exception as exc:
        LOG.warning("Transfer connector log write failed for %s: %s", group, exc)


def _split_s3_path(path: str) -> tuple[str, str]:
    trimmed = path.lstrip("/")
    bucket, _, key = trimmed.partition("/")
    if not bucket or not key:
        raise _TransferFailure("PATH_INVALID", f"Send path must be /bucket/key, got {path}")
    return bucket, key


def _run_transfer(transfer_id: str, connector: dict, account: str, region: str) -> None:
    transfer = _TRANSFERS[transfer_id]
    results = transfer["results"]
    log_clients = None
    if connector.get("LoggingRole"):
        try:
            log_clients = _role_clients(
                connector, connector["LoggingRole"], account, region, ["logs"]
            )
        except _TransferFailure as exc:
            LOG.warning("Transfer logging role unusable: %s", exc.message)

    def fail_all(exc: _TransferFailure) -> None:
        for item in results:
            item.update(StatusCode="FAILED", FailureCode=exc.code, FailureMessage=exc.message)
        _log_event(connector, log_clients, transfer_id, **{"event-type": "TRANSFER_FAILED", "failure-code": exc.code, "message": exc.message})

    for item in results:
        item["StatusCode"] = "IN_PROGRESS"
    _log_event(connector, log_clients, transfer_id, **{"event-type": "TRANSFER_STARTED", "files": [r["FilePath"] for r in results]})
    try:
        if connector.get("As2Config"):
            raise _TransferFailure("UNSUPPORTED", "AS2 connectors are not supported")
        clients = _role_clients(
            connector, connector["AccessRole"], account, region, ["s3", "secretsmanager"]
        )
        secret = _read_user_secret(clients, connector)
        transport, sftp, _ = _open_sftp(connector, secret)
    except _TransferFailure as exc:
        fail_all(exc)
        return
    try:
        remote_dir = transfer["remote_dir"]
        for item in results:
            path = item["FilePath"]
            try:
                bucket, key = _split_s3_path(path)
                try:
                    body = clients["s3"].get_object(Bucket=bucket, Key=key)["Body"].read()
                except Exception as exc:
                    code, message = _client_error_text(exc)
                    raise _TransferFailure(
                        "ACCESS_DENIED_S3" if _denied(code) else "S3_ERROR",
                        f"Reading s3://{bucket}/{key}: {code}: {message}",
                    )
                remote = posixpath.join(remote_dir, posixpath.basename(key))
                try:
                    sftp.putfo(io.BytesIO(body), remote)
                except Exception as exc:
                    raise _TransferFailure("SFTP_WRITE_FAILED", f"Writing {remote}: {exc}")
                item["StatusCode"] = "COMPLETED"
                _log_event(connector, log_clients, transfer_id, **{"event-type": "SEND_FILE_COMPLETED", "file-path": path, "remote-path": remote, "bytes": len(body)})
            except _TransferFailure as exc:
                item.update(StatusCode="FAILED", FailureCode=exc.code, FailureMessage=exc.message)
                _log_event(connector, log_clients, transfer_id, **{"event-type": "SEND_FILE_FAILED", "file-path": path, "failure-code": exc.code, "message": exc.message})
    finally:
        sftp.close()
        transport.close()


def start_file_transfer(context, request):
    connector = _get_connector(context, request)
    send = request.get("SendFilePaths") or []
    if request.get("RetrieveFilePaths"):
        raise _error("InvalidRequestException", "RetrieveFilePaths is not supported by awsbox (send only)")
    if not send or not request.get("RemoteDirectoryPath"):
        raise _error(
            "InvalidRequestException", "SendFilePaths and RemoteDirectoryPath are required"
        )
    transfer_id = secrets.token_hex(16)
    _TRANSFERS[transfer_id] = {
        "connector_id": connector["ConnectorId"],
        "account": context.account_id,
        "region": context.region,
        "remote_dir": request["RemoteDirectoryPath"],
        "results": [{"FilePath": p, "StatusCode": "QUEUED"} for p in send],
    }
    threading.Thread(
        target=_run_transfer_safe,
        args=(transfer_id, dict(connector), context.account_id, context.region),
        daemon=True,
        name=f"transfer-{transfer_id[:8]}",
    ).start()
    return {"TransferId": transfer_id}


def _run_transfer_safe(transfer_id, connector, account, region) -> None:
    try:
        _run_transfer(transfer_id, connector, account, region)
    except Exception as exc:
        LOG.exception("transfer %s crashed", transfer_id)
        for item in _TRANSFERS[transfer_id]["results"]:
            if item["StatusCode"] in ("QUEUED", "IN_PROGRESS"):
                item.update(StatusCode="FAILED", FailureCode="INTERNAL", FailureMessage=str(exc))


def list_file_transfer_results(context, request):
    transfer = _TRANSFERS.get(request.get("TransferId") or "")
    connector = _get_connector(context, request)
    if (
        transfer is None
        or transfer["connector_id"] != connector["ConnectorId"]
        or transfer["account"] != context.account_id
    ):
        raise _error("ResourceNotFoundException", f"Unknown transfer: {request.get('TransferId')}")
    return {"FileTransferResults": [dict(r) for r in transfer["results"]]}


# ---- wiring ----------------------------------------------------------------


def _install() -> None:
    from localemu.services import stub_providers

    ops = stub_providers._OPS.setdefault("transfer", {})
    ops.update(
        {
            "CreateConnector": create_connector,
            "DescribeConnector": describe_connector,
            "UpdateConnector": update_connector,
            "DeleteConnector": delete_connector,
            "ListConnectors": list_connectors,
            "TestConnection": test_connection,
            "StartFileTransfer": start_file_transfer,
            "ListFileTransferResults": list_file_transfer_results,
        }
    )
    LOG.info("awsbox Transfer connectors applied")
    threading.Thread(target=_prewarm, daemon=True, name="transfer-paramiko").start()


def _prewarm() -> None:
    try:
        _paramiko()
    except Exception as exc:
        LOG.warning("paramiko prewarm failed (will retry on first transfer): %s", exc)


_install()
