"""Refresh assumed-role credentials used by long-lived ESM pollers (#475).

LocalEmu's ``connect_to.with_assumed_role`` freezes STS session keys into the
boto client. SQS / Kinesis / DynamoDB stream ESM pollers keep that client for
the life of the mapping, so after the default 1h session the next
``ReceiveMessage`` / ``GetRecords`` fails with ``ExpiredTokenException`` forever
while ``State`` stays Enabled and ``LastProcessingResult`` stays empty.

Real AWS refreshes the poller's credentials. This patch:

1. Honours ``AWSBOX_STS_ASSUME_ROLE_DURATION`` (seconds) as the STS AssumeRole
   default so smokes can expire sessions in minutes instead of an hour.
2. Makes ``ClientFactory.with_assumed_role`` attach botocore
   ``RefreshableCredentials`` so every long-lived assumed-role client
   (ESM source pollers and anything else on that path) re-assumes before expiry.
3. Surfaces credential poll failures on the mapping via ``LastProcessingResult``.
"""

from __future__ import annotations

import logging
import os
import sys

if "/opt/awsbox/esm" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/esm")

import awsbox_esm_common as esm  # noqa: E402

LOG = logging.getLogger("localemu.awsbox.esm_cred_refresh")

_CRED_ERROR_MARKERS = (
    "ExpiredToken",
    "ExpiredTokenException",
    "InvalidClientTokenId",
    "UnrecognizedClientException",
    "AccessDenied",
    "NoSuchEntity",
    "Could not connect to the endpoint",
)

_CRED_FAIL_PREFIX = "PROBLEM: "


def _configured_assume_role_duration() -> int | None:
    raw = (
        os.environ.get("AWSBOX_STS_ASSUME_ROLE_DURATION")
        or os.environ.get("STACKWRANGLER_STS_ASSUME_ROLE_DURATION")
        or ""
    ).strip()
    if not raw:
        return None
    try:
        value = int(raw)
    except ValueError:
        LOG.warning("Ignoring invalid AWSBOX_STS_ASSUME_ROLE_DURATION=%r", raw)
        return None
    if value < 1:
        LOG.warning("Ignoring non-positive AWSBOX_STS_ASSUME_ROLE_DURATION=%r", raw)
        return None
    return value


def _apply_sts_duration_knob() -> int | None:
    """Shorten (or lengthen) the emulator's AssumeRole default for smokes.

    Also rewrites ``Credentials.Expiration`` on the AssumeRole response so it
    matches the session-store TTL. Upstream LocalEmu only updates the store;
    moto's response still advertises ~3600s, which would leave RefreshableCredentials
    refreshing too late while LocalEmu already rejects the token.
    """
    duration = _configured_assume_role_duration()
    if duration is None:
        return None
    try:
        from datetime import datetime, timedelta, timezone

        from localemu.services.sts import provider as sts_provider
        from localemu.services.sts.provider import StsProvider
    except Exception as e:
        LOG.warning("STS duration knob skipped (provider import failed): %s", e)
        return None

    sts_provider._ASSUME_ROLE_DEFAULT_DURATION = duration
    # Allow sub-900s for local smokes; real AWS still enforces 900 via API.
    if hasattr(sts_provider, "_ASSUME_ROLE_MIN_DURATION"):
        sts_provider._ASSUME_ROLE_MIN_DURATION = min(
            int(sts_provider._ASSUME_ROLE_MIN_DURATION), duration
        )

    if not getattr(StsProvider, "_awsbox_sts_duration_response", False):
        original_assume = StsProvider.assume_role

        def assume_role(self, context, *args, **kwargs):
            response = original_assume(self, context, *args, **kwargs)
            creds = response.get("Credentials") if isinstance(response, dict) else None
            if isinstance(creds, dict):
                effective = kwargs.get("duration_seconds")
                if effective is None:
                    effective = duration
                creds["Expiration"] = datetime.now(timezone.utc) + timedelta(
                    seconds=int(effective)
                )
            return response

        StsProvider.assume_role = assume_role
        StsProvider._awsbox_sts_duration_response = True

    LOG.info("awsbox STS AssumeRole default duration set to %ss", duration)
    return duration


def _expiry_iso(expiration) -> str:
    if hasattr(expiration, "isoformat"):
        return expiration.isoformat()
    return str(expiration)


def _refresh_timeouts(duration: int | None) -> dict:
    if not duration:
        return {}
    # Keep advisory/mandatory windows inside the session so short smoke
    # durations still refresh before LocalEmu rejects the token.
    advisory = max(15, duration // 5)
    mandatory = max(5, duration // 10)
    if mandatory >= duration:
        mandatory = max(1, duration // 2)
    if advisory >= duration:
        advisory = max(mandatory + 1, duration * 2 // 3)
    return {"advisory_timeout": advisory, "mandatory_timeout": mandatory}


def _unwrap_client(client):
    raw = client
    seen = 0
    while hasattr(raw, "_client") and seen < 5:
        raw = raw._client
        seen += 1
    return raw


def _inject_refreshable(client, refreshable) -> None:
    raw = _unwrap_client(client)
    signer = getattr(raw, "_request_signer", None)
    if signer is None:
        return
    signer._credentials = refreshable


def _force_credential_refresh(client) -> bool:
    raw = _unwrap_client(client)
    signer = getattr(raw, "_request_signer", None)
    if signer is None:
        return False
    creds = getattr(signer, "_credentials", None)
    if creds is None:
        return False
    try:
        # RefreshableCredentials refreshes inside get_frozen_credentials.
        if hasattr(creds, "get_frozen_credentials"):
            creds.get_frozen_credentials()
            return True
    except Exception as e:
        LOG.debug("forced credential refresh failed: %s", e)
    return False


def _is_credential_error(exc: BaseException) -> bool:
    text = f"{type(exc).__name__}: {exc}"
    code = getattr(exc, "response", None)
    if isinstance(code, dict):
        err = code.get("Error") or {}
        if isinstance(err, dict) and err.get("Code"):
            text = f"{err.get('Code')}: {text}"
    return any(marker in text for marker in _CRED_ERROR_MARKERS)


def _set_last_processing_result(worker, result: str) -> None:
    worker.last_processing_result = result
    lock = getattr(worker, "_state_lock", None)
    state = getattr(worker, "_state", None)
    if lock is None or state is None:
        return
    with lock:
        esm_cfg = state.event_source_mappings.get(worker.uuid)
        if esm_cfg is not None:
            esm_cfg["LastProcessingResult"] = result


def _credential_failure_result(exc: BaseException) -> str:
    code = type(exc).__name__
    response = getattr(exc, "response", None)
    if isinstance(response, dict):
        err = response.get("Error") or {}
        if isinstance(err, dict) and err.get("Code"):
            code = str(err["Code"])
    return f"{_CRED_FAIL_PREFIX}{code}"


def _patch_with_assumed_role() -> None:
    from botocore.credentials import RefreshableCredentials
    from localemu.aws.connect import ClientFactory
    from localemu.utils.strings import short_uid

    if getattr(ClientFactory, "_awsbox_esm_cred_refresh", False):
        return

    duration = _configured_assume_role_duration()

    def with_assumed_role(
        self,
        *,
        role_arn: str,
        service_principal=None,
        session_name: str | None = None,
        region_name: str | None = None,
        endpoint_url: str | None = None,
        config=None,
    ):
        session_name = session_name or f"session-{short_uid()}"

        def fetch_credentials():
            sts_client = self(
                endpoint_url=endpoint_url, config=config, region_name=region_name
            ).sts
            metadata = {}
            if service_principal:
                metadata["service_principal"] = service_principal
            sts_client = sts_client.request_metadata(**metadata)
            # Do not pass DurationSeconds here: botocore rejects values <900
            # client-side. Short sessions come from the patched STS default
            # (AWSBOX_STS_ASSUME_ROLE_DURATION) when DurationSeconds is omitted.
            credentials = sts_client.assume_role(
                RoleArn=role_arn,
                RoleSessionName=session_name,
            )["Credentials"]
            return {
                "access_key": credentials["AccessKeyId"],
                "secret_key": credentials["SecretAccessKey"],
                "token": credentials["SessionToken"],
                "expiry_time": _expiry_iso(credentials["Expiration"]),
            }

        metadata = fetch_credentials()
        refreshable = RefreshableCredentials.create_from_metadata(
            metadata=metadata,
            refresh_using=fetch_credentials,
            method="sts-assume-role",
            **_refresh_timeouts(duration),
        )

        factory = self(
            region_name=region_name,
            aws_access_key_id=metadata["access_key"],
            aws_secret_access_key=metadata["secret_key"],
            aws_session_token=metadata["token"],
            endpoint_url=endpoint_url,
            config=config,
        )
        return _RefreshingAssumedRoleFactory(factory, refreshable)

    ClientFactory.with_assumed_role = with_assumed_role
    ClientFactory._awsbox_esm_cred_refresh = True
    LOG.info("awsbox assumed-role RefreshableCredentials patch applied")


class _RefreshingAssumedRoleFactory:
    """ServiceLevelClientFactory stand-in that injects refreshable STS creds."""

    def __init__(self, factory, refreshable):
        self._factory = factory
        self._refreshable = refreshable

    def get_client(self, service: str):
        wrapped = self._factory.get_client(service)
        _inject_refreshable(wrapped, self._refreshable)
        return wrapped

    def __getattr__(self, service: str):
        wrapped = getattr(self._factory, service)
        _inject_refreshable(wrapped, self._refreshable)
        return wrapped


def _wrap_worker_poll(worker) -> None:
    poller = getattr(worker, "poller", None)
    if poller is None or getattr(poller, "_awsbox_esm_cred_refresh_poll", False):
        return

    from localemu.services.lambda_.event_source_mapping.pollers.poller import (
        EmptyPollResultsException,
    )

    original_poll = poller.poll_events

    def poll_events():
        try:
            result = original_poll()
            if getattr(worker, "_awsbox_cred_error", False):
                _set_last_processing_result(worker, "OK")
                worker._awsbox_cred_error = False
            return result
        except EmptyPollResultsException:
            if getattr(worker, "_awsbox_cred_error", False):
                _set_last_processing_result(worker, "OK")
                worker._awsbox_cred_error = False
            raise
        except Exception as first:
            if not _is_credential_error(first):
                raise
            source_client = getattr(poller, "source_client", None)
            if source_client is not None:
                _force_credential_refresh(source_client)
            try:
                result = original_poll()
                if getattr(worker, "_awsbox_cred_error", False):
                    _set_last_processing_result(worker, "OK")
                    worker._awsbox_cred_error = False
                return result
            except EmptyPollResultsException:
                if getattr(worker, "_awsbox_cred_error", False):
                    _set_last_processing_result(worker, "OK")
                    worker._awsbox_cred_error = False
                raise
            except Exception as second:
                result = _credential_failure_result(second)
                LOG.warning(
                    "ESM credential poll failure uuid=%s result=%s err=%s",
                    getattr(worker, "uuid", "?"),
                    result,
                    second,
                )
                _set_last_processing_result(worker, result)
                worker._awsbox_cred_error = True
                raise

    poller.poll_events = poll_events
    poller._awsbox_esm_cred_refresh_poll = True


def _patch_poller_loop() -> None:
    from localemu.services.lambda_.event_source_mapping.esm_worker import EsmWorker

    if getattr(EsmWorker, "_awsbox_esm_cred_refresh_poll", False):
        return

    original_loop = EsmWorker.poller_loop

    def poller_loop(self, *args, **kwargs):
        _wrap_worker_poll(self)
        return original_loop(self, *args, **kwargs)

    EsmWorker.poller_loop = poller_loop
    EsmWorker._awsbox_esm_cred_refresh_poll = True


def _patch() -> None:
    _apply_sts_duration_knob()
    _patch_with_assumed_role()
    _patch_poller_loop()
    # Touch shared helpers so the mount stays load-tested with this patch.
    _ = esm.request_get
    LOG.info("awsbox ESM assumed-role credential refresh applied")


_patch()
