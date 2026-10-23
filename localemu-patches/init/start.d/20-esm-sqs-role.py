"""Refuse CreateEventSourceMapping when the Lambda role lacks SQS poll perms (#266).

LocalEmu calls GetQueueAttributes as the function role via an internal client, but
IAM_ENFORCEMENT skips internal hops — so a role with no SQS policy still creates a
mapping. Real AWS returns InvalidParameterValueException when the execution role
cannot ReceiveMessage / DeleteMessage / GetQueueAttributes.

Patches Skeleton.dispatch_request (dynamic on every call) under IAM_ENFORCEMENT.
"""

from __future__ import annotations

import logging
import os

LOG = logging.getLogger("localemu.awsbox.esm_sqs_role")

_SQS_POLL_ACTIONS = (
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes",
)


def _iam_enabled() -> bool:
    mode = os.environ.get("IAM_ENFORCEMENT", "").strip().lower()
    return mode == "1" or mode == "soft"


def _iam_enforce() -> bool:
    return os.environ.get("IAM_ENFORCEMENT", "").strip().lower() == "1"


def _role_name_from_arn(role_arn: str) -> str | None:
    if not role_arn or ":role/" not in role_arn:
        return None
    return role_arn.rsplit("/", 1)[-1] or None


def _request_get(request, key: str):
    if request is None:
        return None
    if isinstance(request, dict):
        return request.get(key)
    getter = getattr(request, "get", None)
    if callable(getter):
        return getter(key)
    return getattr(request, key, None)


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


def _function_role(function_ref: str, account_id: str, region: str) -> str | None:
    from localemu.services.lambda_ import api_utils
    from localemu.services.lambda_.api_utils import function_locators_from_arn
    from localemu.services.lambda_.invocation.models import lambda_stores
    from localemu.services.lambda_.provider_utils import get_function_version_from_arn

    function_name, qualifier, account, fn_region = function_locators_from_arn(function_ref)
    account = account or account_id
    fn_region = fn_region or region
    state = lambda_stores[account][fn_region]
    fn = state.functions.get(function_name)
    if not fn:
        return None
    if qualifier:
        fn_arn = api_utils.qualified_lambda_arn(function_name, qualifier, account, fn_region)
    else:
        fn_arn = api_utils.unqualified_lambda_arn(function_name, account, fn_region)
    version = get_function_version_from_arn(fn_arn)
    return version.config.role


def _enforce_from_request(context, request) -> None:
    if not _iam_enabled():
        return
    service = getattr(context, "service", None)
    operation = getattr(context, "operation", None)
    if getattr(service, "service_name", None) != "lambda":
        return
    if getattr(operation, "name", None) != "CreateEventSourceMapping":
        return

    source_arn = _request_get(request, "EventSourceArn")
    if not isinstance(source_arn, str) or ":sqs:" not in source_arn:
        return

    function_ref = _request_get(request, "FunctionName") or _request_get(request, "FunctionArn")
    if not isinstance(function_ref, str) or not function_ref:
        return

    account_id = getattr(context, "account_id", None) or "000000000000"
    region = getattr(context, "region", None) or "us-east-1"
    try:
        role_arn = _function_role(function_ref, account_id, region)
    except Exception as e:
        LOG.debug("ESM SQS role lookup failed: %s", e)
        return
    if not role_arn:
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
    LOG.info("awsbox ESM SQS execution-role check applied")


_patch()
