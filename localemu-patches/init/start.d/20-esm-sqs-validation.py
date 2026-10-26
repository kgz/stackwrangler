"""Refuse CreateEventSourceMapping when SQS visibility < function timeout
or MaximumConcurrency < 2 (#363).

Real AWS returns InvalidParameterValueException for both. LocalEmu accepts them,
so stacks that pass locally can fail on deploy, and retry timing is wrong when
visibility expires while the function is still running.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.esm_sqs_validation")

_MAX_CONCURRENCY_MIN = 2


def _request_get(request, key: str):
    if request is None:
        return None
    if isinstance(request, dict):
        return request.get(key)
    getter = getattr(request, "get", None)
    if callable(getter):
        return getter(key)
    return getattr(request, key, None)


def _function_timeout(function_ref: str, account_id: str, region: str) -> int | None:
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
    timeout = getattr(version.config, "timeout", None)
    if timeout is None:
        return None
    return int(timeout)


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
    scaling = _request_get(request, "ScalingConfig")
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


def _enforce_visibility_vs_timeout(context, request) -> None:
    source_arn = _request_get(request, "EventSourceArn")
    if not isinstance(source_arn, str) or ":sqs:" not in source_arn:
        return

    function_ref = _request_get(request, "FunctionName") or _request_get(request, "FunctionArn")
    if not isinstance(function_ref, str) or not function_ref:
        return

    account_id = getattr(context, "account_id", None) or "000000000000"
    region = getattr(context, "region", None) or "us-east-1"
    try:
        fn_timeout = _function_timeout(function_ref, account_id, region)
        visibility = _queue_visibility_timeout(source_arn, account_id, region)
    except Exception as e:
        LOG.debug("ESM SQS visibility check lookup failed: %s", e)
        return
    if fn_timeout is None or visibility is None:
        return
    if visibility >= fn_timeout:
        return

    from localemu.aws.api.lambda_ import InvalidParameterValueException

    raise InvalidParameterValueException(
        f"Invalid value for attribute: Queue visibility timeout: {visibility} seconds "
        f"is less than Function timeout: {fn_timeout} seconds",
        Type="User",
    )


def _enforce_from_request(context, request) -> None:
    service = getattr(context, "service", None)
    operation = getattr(context, "operation", None)
    if getattr(service, "service_name", None) != "lambda":
        return
    if getattr(operation, "name", None) != "CreateEventSourceMapping":
        return

    _enforce_maximum_concurrency(request)
    _enforce_visibility_vs_timeout(context, request)


def _patch() -> None:
    from localemu.aws.skeleton import Skeleton

    if getattr(Skeleton, "_awsbox_esm_sqs_validation", False):
        return

    original = Skeleton.dispatch_request

    def dispatch_request(self, serializer, context, instance):
        _enforce_from_request(context, instance)
        return original(self, serializer, context, instance)

    Skeleton.dispatch_request = dispatch_request
    Skeleton._awsbox_esm_sqs_validation = True
    LOG.info("awsbox ESM SQS visibility/concurrency validation applied")


_patch()
