"""Refuse CreateEventSourceMapping when the Lambda role lacks SQS poll perms (#266),
queue VisibilityTimeout < function timeout, or MaximumConcurrency < 2 (#363).

LocalEmu calls GetQueueAttributes as the function role via an internal client, but
IAM_ENFORCEMENT skips internal hops — so a role with no SQS policy still creates a
mapping. Real AWS returns InvalidParameterValueException when the execution role
cannot ReceiveMessage / DeleteMessage / GetQueueAttributes, when visibility is
shorter than the function timeout, or when MaximumConcurrency is below 2.

Patches Skeleton.dispatch_request (dynamic on every call). Role check runs under
IAM_ENFORCEMENT; visibility/concurrency always apply.
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


def _enforce_from_request(context, request) -> None:
    service = getattr(context, "service", None)
    operation = getattr(context, "operation", None)
    if getattr(service, "service_name", None) != "lambda":
        return
    if getattr(operation, "name", None) != "CreateEventSourceMapping":
        return

    _enforce_maximum_concurrency(request)

    source_arn = esm.request_get(request, "EventSourceArn")
    if not isinstance(source_arn, str) or ":sqs:" not in source_arn:
        return

    function_ref = esm.request_get(request, "FunctionName") or esm.request_get(
        request, "FunctionArn"
    )
    if not isinstance(function_ref, str) or not function_ref:
        return

    account_id = getattr(context, "account_id", None) or "000000000000"
    region = getattr(context, "region", None) or "us-east-1"
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
    LOG.info("awsbox ESM SQS role/visibility/concurrency checks applied")


_patch()
