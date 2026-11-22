"""Lambda PERSISTENCE restore: wait for code spool + gateway; mark Failed (#713/#751).

``boot.d`` runs in a separate entrypoint process, so monkeypatches there never
reach the main LocalEmu server. This lives in ``start.d`` (in-process).

Persistence load (``on_infra_start`` priority 5) runs *before* start.d
(priority 0) and schedules deferred restore on a worker thread. As of #751,
``state_persistence`` restores ``s3_bodies`` *before* Lambda's post-load hook
so the in-process S3 fast path usually hits. We still:

1. Patch ``_run_deferred_restore`` to wait for spool + gateway (HTTP fallback
   for missing bodies / non-internal buckets must not race ``localhost:4566``).
2. Run a late sweep in case the worker already finished the unpatched path.
3. Surface unrestored ``Pending`` as ``Failed`` with an actionable reason so
   ``UpdateFunctionCode`` can replace them (#713).
"""

from __future__ import annotations

import dataclasses
import logging
import os
import socket
import threading
import time
from io import BytesIO

LOG = logging.getLogger("localemu.awsbox.lambda_persist_restore")

# Smokes can shrink the wait (e.g. AWSBOX_LAMBDA_PERSIST_CODE_WAIT_S=2) after
# deliberately wiping persisted s3_bodies so Failed marking is prompt.
def _code_wait_s() -> float:
    raw = (
        os.environ.get("STACKWRANGLER_LAMBDA_PERSIST_CODE_WAIT_S")
        or os.environ.get("AWSBOX_LAMBDA_PERSIST_CODE_WAIT_S")
        or "45"
    )
    try:
        return max(0.0, float(raw))
    except ValueError:
        return 45.0


def _gateway_wait_s() -> float:
    raw = (
        os.environ.get("STACKWRANGLER_LAMBDA_PERSIST_GATEWAY_WAIT_S")
        or os.environ.get("AWSBOX_LAMBDA_PERSIST_GATEWAY_WAIT_S")
        or "60"
    )
    try:
        return max(0.0, float(raw))
    except ValueError:
        return 60.0


_CODE_POLL_S = 0.5
_GATEWAY_POLL_S = 0.25
# Upstream create_function_version().result(timeout=30) during deferred restore.
_DEFERRED_CREATE_TIMEOUT_S = 35.0
_MISSING_CODE_REASON = (
    "Function code is unavailable after LocalEmu restart; "
    "call UpdateFunctionCode to replace it."
)
_GATEWAY_FAIL_REASON = (
    "Function restore could not reach the LocalEmu gateway (localhost:4566) "
    "to download code; retry after the emulator is ready, or call "
    "UpdateFunctionCode to replace the zip."
)


def _code_in_spool(fn_version) -> bool:
    """True when zip bytes are already in EphemeralS3ObjectStore (or no zip)."""
    code = getattr(fn_version.config, "code", None)
    if code is None:
        return True
    bucket = getattr(code, "s3_bucket", None)
    key = getattr(code, "s3_key", None)
    if not bucket or not key:
        return True
    try:
        from localemu.services.lambda_.invocation.lambda_models import (
            _try_read_archive_from_local_store,
        )

        return _try_read_archive_from_local_store(
            bucket=bucket,
            key=key,
            version_id=getattr(code, "s3_object_version", None),
            target_file=BytesIO(),
        )
    except Exception:
        LOG.debug("code spool probe failed", exc_info=True)
        return False


def _layer_codes_in_spool(fn_version) -> bool:
    layers = getattr(fn_version.config, "layers", None) or []
    for layer in layers:
        code = getattr(layer, "code", None)
        if code is None:
            continue
        bucket = getattr(code, "s3_bucket", None)
        key = getattr(code, "s3_key", None)
        if not bucket or not key:
            continue
        try:
            from localemu.services.lambda_.invocation.lambda_models import (
                _try_read_archive_from_local_store,
            )

            if not _try_read_archive_from_local_store(
                bucket=bucket,
                key=key,
                version_id=getattr(code, "s3_object_version", None),
                target_file=BytesIO(),
            ):
                return False
        except Exception:
            LOG.debug("layer spool probe failed", exc_info=True)
            return False
    return True


def _pending_versions(pending_functions):
    from localemu.aws.api.lambda_ import State

    out = []
    for fn in pending_functions:
        for fn_version in list(fn.versions.values()):
            if fn_version.config.state.state == State.Pending:
                out.append((fn, fn_version))
    return out


def _pending_from_store():
    from localemu.aws.api.lambda_ import State
    from localemu.services.lambda_.invocation.models import lambda_stores

    out = []
    for account_bundle in lambda_stores.values():
        for region_state in account_bundle.values():
            for fn in region_state.functions.values():
                for fn_version in list(fn.versions.values()):
                    if fn_version.config.state.state == State.Pending:
                        out.append((fn, fn_version))
    return out


def _wait_for_code_spool(pending_functions) -> None:
    wait_s = _code_wait_s()
    deadline = time.monotonic() + wait_s
    while time.monotonic() < deadline:
        pending = _pending_versions(pending_functions)
        if not pending:
            return
        if all(
            _code_in_spool(v) and _layer_codes_in_spool(v) for _, v in pending
        ):
            LOG.info(
                "Lambda persistence restore: code spool ready for %d version(s)",
                len(pending),
            )
            return
        time.sleep(_CODE_POLL_S)
    LOG.warning(
        "Lambda persistence restore: code spool still incomplete after %.0fs "
        "(UpdateFunctionCode can replace Failed versions)",
        wait_s,
    )


def _gateway_listen_addr() -> tuple[str, int]:
    try:
        from localemu import config

        listen = config.GATEWAY_LISTEN[0]
        host = getattr(listen, "host", None) or "127.0.0.1"
        if host in ("0.0.0.0", "::", "[::]"):
            host = "127.0.0.1"
        return host, int(listen.port)
    except Exception:
        return "127.0.0.1", 4566


def _gateway_accepts_tcp() -> bool:
    host, port = _gateway_listen_addr()
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def _wait_for_gateway() -> bool:
    """Block until the edge gateway accepts TCP (boto3 HTTP fallback needs it)."""
    wait_s = _gateway_wait_s()
    if wait_s <= 0:
        return _gateway_accepts_tcp()
    deadline = time.monotonic() + wait_s
    while time.monotonic() < deadline:
        if _gateway_accepts_tcp():
            LOG.info(
                "Lambda persistence restore: gateway ready at %s:%s",
                *_gateway_listen_addr(),
            )
            return True
        time.sleep(_GATEWAY_POLL_S)
    LOG.warning(
        "Lambda persistence restore: gateway not accepting connections after "
        "%.0fs — HTTP code download may fail with EndpointConnectionError (#751)",
        wait_s,
    )
    return False


def _mark_version_failed(fn, fn_version, *, reason: str = _MISSING_CODE_REASON) -> None:
    from localemu.aws.api.lambda_ import LastUpdateStatus, State, StateReasonCode
    from localemu.services.lambda_.invocation.lambda_models import (
        UpdateStatus,
        VersionState,
    )

    new_state = VersionState(
        state=State.Failed,
        code=StateReasonCode.InvalidZipFileException,
        reason=reason,
    )
    new_config = dataclasses.replace(
        fn_version.config,
        state=new_state,
        last_update=UpdateStatus(status=LastUpdateStatus.Failed),
    )
    fn.versions[fn_version.id.qualifier] = dataclasses.replace(
        fn_version, config=new_config
    )


def _discard_starting(lambda_service, qualified_arn: str) -> None:
    if lambda_service is None:
        return
    with lambda_service.lambda_version_manager_lock:
        stale = lambda_service.lambda_starting_versions.pop(qualified_arn, None)
    if stale is not None:
        lambda_service.task_executor.submit(stale.stop)


def _lambda_service_from_provider(provider):
    return getattr(provider, "lambda_service", None)


def _mark_pending_failed(pending_pairs, lambda_service, *, reason: str = _MISSING_CODE_REASON) -> int:
    from localemu.aws.api.lambda_ import State

    marked = 0
    for fn, fn_version in pending_pairs:
        live = fn.versions.get(fn_version.id.qualifier) or fn_version
        if live.config.state.state != State.Pending:
            continue
        LOG.warning(
            "Marking unrestored Lambda version Failed: %s (%s)",
            live.id.qualified_arn(),
            reason,
        )
        _mark_version_failed(fn, live, reason=reason)
        _discard_starting(lambda_service, live.id.qualified_arn())
        marked += 1
    return marked


def _patch_deferred_restore() -> None:
    from localemu.services.lambda_.provider import LambdaProvider

    original = LambdaProvider._run_deferred_restore

    def _run_deferred_restore(self, pending_functions, pending_esms) -> None:
        _wait_for_code_spool(pending_functions)
        gateway_ok = _wait_for_gateway()
        original(self, pending_functions, pending_esms)

        # Upstream leaves Pending when create never ran or timed out before
        # start() could report Failed. Surface that as Failed so clients and
        # UpdateFunctionCode see a terminal state (#713). Prefer a gateway
        # hint when TCP never came up (#751).
        reason = _MISSING_CODE_REASON if gateway_ok else _GATEWAY_FAIL_REASON
        _mark_pending_failed(
            _pending_versions(pending_functions),
            _lambda_service_from_provider(self),
            reason=reason,
        )

    LambdaProvider._run_deferred_restore = _run_deferred_restore


def _late_sweep_pending() -> None:
    """Mark restore-era Pending leftovers if deferred restore raced our patch.

    Snapshot Pending ARNs after a short delay (Phase 1 may still be landing if
    start.d raced ahead of state load), then wait for deferred restore. Never
    re-scan the whole store after user traffic — that raced cold
    ``create-function`` under short smoke wait_s (#713).
    """
    snap_s = 1.0
    time.sleep(snap_s)
    try:
        restore_arns = frozenset(
            ver.id.qualified_arn() for _, ver in _pending_from_store()
        )
    except Exception:
        LOG.exception("Lambda persistence late sweep snapshot failed (#713)")
        return
    if not restore_arns:
        LOG.info("Lambda persistence late sweep: no restore-era Pending (#713)")
        return
    remaining = max(
        0.0,
        _code_wait_s() + _gateway_wait_s() + _DEFERRED_CREATE_TIMEOUT_S - snap_s,
    )
    time.sleep(remaining)
    try:
        from localemu.services.plugins import SERVICE_PLUGINS

        svc = SERVICE_PLUGINS.get_service("lambda")
        provider = getattr(svc, "_provider", None) if svc else None
        lambda_service = _lambda_service_from_provider(provider)
        pairs = [
            (fn, ver)
            for fn, ver in _pending_from_store()
            if ver.id.qualified_arn() in restore_arns
        ]
        marked = _mark_pending_failed(pairs, lambda_service)
        if marked:
            LOG.info(
                "Lambda persistence late sweep: marked %d Pending version(s) Failed (#713)",
                marked,
            )
    except Exception:
        LOG.exception("Lambda persistence late sweep failed (#713)")


try:
    _patch_deferred_restore()
    threading.Thread(
        target=_late_sweep_pending,
        name="lambda-persist-failed-sweep",
        daemon=True,
    ).start()
    LOG.info(
        "Lambda persistence restore wait/Failed marking installed (#713/#751)"
    )
except Exception:
    LOG.exception("Failed to install Lambda persistence restore patch (#713/#751)")
