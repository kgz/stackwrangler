"""Evaluate API Gateway management calls as AWS does.

IAM models both API Gateway services as HTTP verbs on path resources:
``apigateway:POST`` on ``arn:aws:apigateway:<region>::/apikeys``,
``apigateway:GET`` on ``.../usageplans/<id>/keys``. The stock enforcer
uses ``apigateway:CreateApiKey`` on a wildcard instead, so a policy written
for AWS never matches. APIs v2 use the same actions, with ``/v2`` dropped.
"""

from __future__ import annotations

import contextvars
import logging

LOG = logging.getLogger("localemu.awsbox.apigw_iam")

_SERVICES = ("apigateway", "apigatewayv2")
_CURRENT = contextvars.ContextVar("awsbox_apigw_iam_request", default=None)


def _verb_and_path(service: str):
    request = _CURRENT.get()
    if request is None or service not in _SERVICES:
        return None
    path = request.path or "/"
    if service == "apigatewayv2" and path.startswith("/v2/"):
        path = path[3:]
    return request.method.upper(), path.rstrip("/") or "/"


def _install() -> None:
    from localemu.services.iam_enforcement import arn_builder, enforcer, service_action_map

    if getattr(enforcer.IAMEnforcementHandler, "_awsbox_apigw_iam", False):
        return

    orig_call = enforcer.IAMEnforcementHandler.__call__
    orig_map = service_action_map.map_action
    orig_build = arn_builder.build_resource_arn
    orig_build_enforcer = enforcer.build_resource_arn

    def __call__(self, chain, context, response):
        token = _CURRENT.set(context.request)
        try:
            return orig_call(self, chain, context, response)
        finally:
            _CURRENT.reset(token)

    def map_action(service, operation_name):
        parts = _verb_and_path(service)
        if parts is None:
            return orig_map(service, operation_name)
        return ["apigateway:" + parts[0]]

    def _wrap_build(original):
        def build_resource_arn(service, operation, request_params, region, account_id):
            parts = _verb_and_path(service)
            if parts is None:
                return original(service, operation, request_params, region, account_id)
            return f"arn:aws:apigateway:{region or 'us-east-1'}::{parts[1]}"

        return build_resource_arn

    enforcer.IAMEnforcementHandler.__call__ = __call__
    service_action_map.map_action = map_action
    arn_builder.build_resource_arn = _wrap_build(orig_build)
    enforcer.build_resource_arn = _wrap_build(orig_build_enforcer)
    enforcer.IAMEnforcementHandler._awsbox_apigw_iam = True
    LOG.info("awsbox API Gateway IAM actions applied")


_install()
