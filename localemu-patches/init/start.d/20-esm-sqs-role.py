"""Refuse Create/UpdateEventSourceMapping when the Lambda role lacks SQS poll
perms (#266), queue VisibilityTimeout < function timeout, or MaximumConcurrency
< 2 (#363 / #367). After create, re-check those SQS actions on each poll so a
later revoke stops consumption (#285).

LocalEmu calls GetQueueAttributes as the function role via an internal client, but
IAM_ENFORCEMENT skips internal hops — so a role with no SQS policy still creates a
mapping, and the poller would keep receiving. Real AWS returns
InvalidParameterValueException when the execution role cannot ReceiveMessage /
DeleteMessage / GetQueueAttributes, when visibility is shorter than the function
timeout, or when MaximumConcurrency is below 2. After create, AWS stops polling
(or surfaces the authz failure on the mapping) if those perms are removed.
UpdateEventSourceMapping gets the same VT/MC (and role) checks so a later update
cannot weaken them (#367).

Patches Skeleton.dispatch_request (create/update-time) and EsmWorker.poller_loop
(runtime). Role checks run under IAM_ENFORCEMENT; visibility/concurrency always
apply on create and update.
"""

from __future__ import annotations

import logging
import os
import sys

if "/opt/awsbox/esm" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/esm")

import awsbox_esm_common as esm  # noqa: E402

LOG = logging.getLogger("localemu.awsbox.esm_sqs_role")

_SQS_POLL_ACTIONS = (
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes",
)
_MAX_CONCURRENCY_MIN = 2


def _iam_enabled() -> bool:
    mode = os.environ.get("IAM_ENFORCEMENT", "").strip().lower()
    return mode == "1" or mode == "soft"


def _iam_enforce() -> bool:
    return os.environ.get("IAM_ENFORCEMENT", "").strip().lower() == "1"


def _role_name_from_arn(role_arn: str) -> str | None:
    if not role_arn or ":role/" not in role_arn:
        return None
    return role_arn.rsplit("/", 1)[-1] or None


def _caller_for_role(role_arn: str, account_id: str):
    from localemu.services.iam_enforcement.identity import CallerIdentity

    role_name = _role_name_from_arn(role_arn)
    if not role_name:
        return None
    return CallerIdentity(
        principal_type="AssumedRole",
        account_id=account_id,
        arn=f"arn:aws:sts::{account_id}:assumed-role/{role_name}/awsbox-esm-check",
        role_name=role_name,
        session_name="awsbox-esm-check",
        acting_services=["lambda.amazonaws.com"],
    )


def _missing_sqs_action(role_arn: str, queue_arn: str, account_id: str, region: str) -> str | None:
    from localemu.services.iam_enforcement.enforcer import _get_resource_policy
    from localemu.services.iam_enforcement.evaluator import Decision, PolicyEvaluator

    caller = _caller_for_role(role_arn, account_id)
    if caller is None:
        return _SQS_POLL_ACTIONS[0]

    resource_policy = _get_resource_policy("sqs", queue_arn, account_id, region)
    conditions = {
        "aws:RequestedRegion": region,
        "aws:PrincipalAccount": account_id,
        "aws:PrincipalArn": caller.arn,
        "aws:SourceAccount": account_id,
    }
    evaluator = PolicyEvaluator()
    for action in _SQS_POLL_ACTIONS:
        decision = evaluator.evaluate(
            caller=caller,
            action=action,
            resource=queue_arn,
            conditions=conditions,
            resource_policy=resource_policy,
        )
        if decision != Decision.ALLOW:
            return action
    return None


def _queue_visibility_timeout(queue_arn: str, account_id: str, region: str) -> int | None:
    from localemu.services.sqs.models import sqs_stores
    from localemu.utils.aws.arns import parse_arn

    parsed = parse_arn(queue_arn)
    queue_account = parsed.get("account") or account_id
    queue_region = parsed.get("region") or region
    queue_name = (parsed.get("resource") or "").split("/", 1)[-1]
    if not queue_name:
        return None
    store = sqs_stores[queue_account][queue_region]
    queue = (getattr(store, "queues", None) or {}).get(queue_name)
    if queue is None:
        return None
    attrs = getattr(queue, "attributes", None) or {}
    raw = attrs.get("VisibilityTimeout")
    if raw is None:
        return int(getattr(queue, "visibility_timeout", 30))
    return int(raw)


def _enforce_maximum_concurrency(request) -> None:
    scaling = esm.request_get(request, "ScalingConfig")
    if not scaling:
        return
    if isinstance(scaling, dict):
        raw = scaling.get("MaximumConcurrency")
    else:
        raw = getattr(scaling, "MaximumConcurrency", None)
        if raw is None and callable(getattr(scaling, "get", None)):
            raw = scaling.get("MaximumConcurrency")
    if raw is None:
        return
    try:
        value = int(raw)
    except (TypeError, ValueError):
        return
    if value >= _MAX_CONCURRENCY_MIN:
        return

    from localemu.aws.api.lambda_ import InvalidParameterValueException

    raise InvalidParameterValueException(
        f"Value {value} at 'scalingConfig.maximumConcurrency' failed to satisfy "
        f"constraint: Member must have value greater than or equal to {_MAX_CONCURRENCY_MIN}.",
        Type="User",
    )


def _enforce_visibility_vs_timeout(source_arn: str, version, account_id: str, region: str) -> None:
    timeout = getattr(getattr(version, "config", None), "timeout", None)
    if timeout is None:
        return
    try:
        fn_timeout = int(timeout)
        visibility = _queue_visibility_timeout(source_arn, account_id, region)
    except Exception as e:
        LOG.debug("ESM SQS visibility check lookup failed: %s", e)
        return
    if visibility is None or visibility >= fn_timeout:
        return

    from localemu.aws.api.lambda_ import InvalidParameterValueException

    raise InvalidParameterValueException(
        f"Invalid value for attribute: Queue visibility timeout: {visibility} seconds "
        f"is less than Function timeout: {fn_timeout} seconds",
        Type="User",
    )


def _enforce_role(role_arn: str, source_arn: str, account_id: str, region: str) -> None:
    if not _iam_enabled():
        return

    from localemu.utils.aws.arns import parse_arn

    try:
        parsed = parse_arn(source_arn)
        queue_account = parsed.get("account") or account_id
        queue_region = parsed.get("region") or region
    except Exception:
        queue_account, queue_region = account_id, region

    missing = _missing_sqs_action(role_arn, source_arn, queue_account, queue_region)
    if missing is None:
        return

    from localemu.aws.api.lambda_ import InvalidParameterValueException

    message = (
        "The function execution role does not have permissions to call "
        "ReceiveMessage on SQS"
    )
    if not _iam_enforce():
        LOG.warning(
            "IAM AUDIT DENY ESM SQS: role=%s missing=%s queue=%s",
            role_arn,
            missing,
            source_arn,
        )
        return
    raise InvalidParameterValueException(message, Type="User")


def _existing_mapping(uuid: str, account_id: str, region: str):
    from localemu.services.lambda_.invocation.models import lambda_stores

    state = lambda_stores[account_id][region]
    return (getattr(state, "event_source_mappings", None) or {}).get(uuid)


def _enforce_from_request(context, request) -> None:
    service = getattr(context, "service", None)
    operation = getattr(context, "operation", None)
    if getattr(service, "service_name", None) != "lambda":
        return
    op_name = getattr(operation, "name", None)
    if op_name not in ("CreateEventSourceMapping", "UpdateEventSourceMapping"):
        return

    _enforce_maximum_concurrency(request)

    account_id = getattr(context, "account_id", None) or "000000000000"
    region = getattr(context, "region", None) or "us-east-1"

    source_arn = esm.request_get(request, "EventSourceArn")
    function_ref = esm.request_get(request, "FunctionName") or esm.request_get(
        request, "FunctionArn"
    )

    if op_name == "UpdateEventSourceMapping":
        uuid = esm.request_get(request, "UUID")
        if not isinstance(uuid, str) or not uuid:
            return
        mapping = _existing_mapping(uuid, account_id, region)
        if not mapping:
            return
        if not isinstance(source_arn, str) or not source_arn:
            source_arn = mapping.get("EventSourceArn")
        if not isinstance(function_ref, str) or not function_ref:
            function_ref = mapping.get("FunctionArn") or mapping.get("FunctionName")

    if not isinstance(source_arn, str) or ":sqs:" not in source_arn:
        return
    if not isinstance(function_ref, str) or not function_ref:
        return

    try:
        version = esm.get_function_version(function_ref, account_id, region)
    except Exception as e:
        LOG.debug("ESM SQS function lookup failed: %s", e)
        return
    if not version:
        return

    _enforce_visibility_vs_timeout(source_arn, version, account_id, region)

    role_arn = getattr(version.config, "role", None)
    if role_arn:
        _enforce_role(role_arn, source_arn, account_id, region)


_AUTHZ_FAIL_RESULT = (
    "PROBLEM: Function execution role does not have permissions to call "
    "ReceiveMessage on SQS"
)


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


def _clear_authz_failure_result(worker) -> None:
    """AWS clears the stuck PROBLEM once SQS polling succeeds again after re-grant."""
    if getattr(worker, "last_processing_result", None) != _AUTHZ_FAIL_RESULT:
        return
    _set_last_processing_result(worker, "OK")


def _poll_role_denied(worker) -> bool:
    """True when IAM enforce is on and the function role lacks SQS poll actions."""
    if not _iam_enforce():
        return False

    source_arn = worker.esm_config.get("EventSourceArn")
    function_arn = worker.esm_config.get("FunctionArn")
    if not isinstance(source_arn, str) or ":sqs:" not in source_arn:
        return False
    if not isinstance(function_arn, str) or not function_arn:
        return False

    from localemu.utils.aws.arns import parse_arn

    try:
        parsed_fn = parse_arn(function_arn)
        account_id = parsed_fn.get("account") or "000000000000"
        region = parsed_fn.get("region") or "us-east-1"
    except Exception:
        account_id, region = "000000000000", "us-east-1"

    try:
        version = esm.get_function_version(function_arn, account_id, region)
    except Exception as e:
        LOG.debug("ESM SQS poll role lookup failed: %s", e)
        return False
    if not version:
        return False

    role_arn = getattr(version.config, "role", None)
    if not role_arn:
        return False

    try:
        parsed_q = parse_arn(source_arn)
        queue_account = parsed_q.get("account") or account_id
        queue_region = parsed_q.get("region") or region
    except Exception:
        queue_account, queue_region = account_id, region

    missing = _missing_sqs_action(role_arn, source_arn, queue_account, queue_region)
    if missing is None:
        return False

    LOG.warning(
        "ESM SQS poll denied: role=%s missing=%s queue=%s uuid=%s",
        role_arn,
        missing,
        source_arn,
        worker.uuid,
    )
    return True


def _wrap_worker_poll(worker) -> None:
    poller = getattr(worker, "poller", None)
    if poller is None or getattr(poller, "_awsbox_esm_sqs_role_poll", False):
        return

    source_arn = worker.esm_config.get("EventSourceArn") or ""
    if ":sqs:" not in source_arn:
        poller._awsbox_esm_sqs_role_poll = True
        return

    from localemu.services.lambda_.event_source_mapping.pollers.poller import (
        EmptyPollResultsException,
    )

    original_poll = poller.poll_events

    def poll_events():
        if _poll_role_denied(worker):
            _set_last_processing_result(worker, _AUTHZ_FAIL_RESULT)
            raise EmptyPollResultsException(service="sqs", source_arn=source_arn)
        try:
            result = original_poll()
        except EmptyPollResultsException:
            # ReceiveMessage succeeded (empty queue) — clear stuck authz PROBLEM (#449).
            _clear_authz_failure_result(worker)
            raise
        _clear_authz_failure_result(worker)
        return result

    poller.poll_events = poll_events
    poller._awsbox_esm_sqs_role_poll = True


def _patch_runtime_poll() -> None:
    from localemu.services.lambda_.event_source_mapping.esm_worker import EsmWorker

    if getattr(EsmWorker, "_awsbox_esm_sqs_role_poll", False):
        return

    original_loop = EsmWorker.poller_loop

    def poller_loop(self, *args, **kwargs):
        _wrap_worker_poll(self)
        return original_loop(self, *args, **kwargs)

    EsmWorker.poller_loop = poller_loop
    EsmWorker._awsbox_esm_sqs_role_poll = True


def _patch() -> None:
    from localemu.aws.skeleton import Skeleton

    if getattr(Skeleton, "_awsbox_esm_sqs_role", False):
        return

    original = Skeleton.dispatch_request

    def dispatch_request(self, serializer, context, instance):
        _enforce_from_request(context, instance)
        return original(self, serializer, context, instance)

    Skeleton.dispatch_request = dispatch_request
    Skeleton._awsbox_esm_sqs_role = True
    _patch_runtime_poll()
    LOG.info(
        "awsbox ESM SQS role/visibility/concurrency (create+update) + poll revoke checks applied"
    )


_patch()
