"""Set lambda:FunctionArn on EventSourceMapping IAM evaluation (#650).

Update/Delete (and Get) take only the mapping UUID. AWS still evaluates
``lambda:FunctionArn`` as the mapping's function, so a deploy role scoped
with ArnLike on that key can create an SQS trigger but never update or
delete it. Create uses FunctionName on the request.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.lambda_esm_function_arn")

_UUID_OPS = frozenset(
    {
        "GetEventSourceMapping",
        "UpdateEventSourceMapping",
        "DeleteEventSourceMapping",
    }
)
_CREATE_OPS = frozenset({"CreateEventSourceMapping"})


def _function_arn_from_ref(function_ref: str, region: str, account_id: str) -> str | None:
    if not function_ref:
        return None
    if function_ref.startswith("arn:"):
        return function_ref
    return f"arn:aws:lambda:{region}:{account_id}:function:{function_ref}"


def _mapping_function_arn(uuid: str, account_id: str, region: str) -> str | None:
    try:
        from localemu.services.lambda_.invocation.models import lambda_stores

        state = lambda_stores[account_id][region]
        mapping = (getattr(state, "event_source_mappings", None) or {}).get(uuid)
        if not mapping:
            return None
        ref = mapping.get("FunctionArn") or mapping.get("FunctionName")
        if not isinstance(ref, str) or not ref:
            return None
        return _function_arn_from_ref(ref, region, account_id)
    except Exception:
        LOG.debug(
            "lambda:FunctionArn mapping lookup failed for %s", uuid, exc_info=True
        )
        return None


def _install() -> None:
    from localemu.services.iam_enforcement import enforcer as enforcer_mod

    if getattr(enforcer_mod._build_conditions, "_awsbox_lambda_esm_function_arn", False):
        return

    orig = enforcer_mod._build_conditions

    def _build_conditions(context, caller):
        conditions = orig(context, caller)
        try:
            service = getattr(getattr(context, "service", None), "service_name", None)
            operation = getattr(getattr(context, "operation", None), "name", None)
            if service != "lambda" or not operation:
                return conditions
            params = context.service_request or {}
            account_id = context.account_id or caller.account_id or "000000000000"
            region = context.region or "us-east-1"
            function_arn = None
            if operation in _CREATE_OPS:
                ref = params.get("FunctionName") or params.get("FunctionArn")
                if isinstance(ref, str) and ref:
                    function_arn = _function_arn_from_ref(ref, region, account_id)
            elif operation in _UUID_OPS:
                uuid = params.get("UUID")
                if isinstance(uuid, str) and uuid:
                    function_arn = _mapping_function_arn(uuid, account_id, region)
            if function_arn:
                conditions["lambda:FunctionArn"] = function_arn
        except Exception:
            LOG.debug("lambda:FunctionArn context failed", exc_info=True)
        return conditions

    _build_conditions._awsbox_lambda_esm_function_arn = True
    enforcer_mod._build_conditions = _build_conditions
    LOG.info("awsbox lambda:FunctionArn EventSourceMapping condition key applied")


_install()
