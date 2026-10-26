"""REST Lambda authorizer Deny → 403 (AWS); missing identity source → 401 (#190).

LocalEmu raises UnauthorizedError (401) for both a missing REQUEST identity
source (after the authorizer returns Deny) and an explicit Deny policy.
AWS returns 401 only when the identity source is absent, and 403 with
``User is not authorized to access this resource`` on Deny.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.apigw_rest_deny_403")

_DENY_MSG = "User is not authorized to access this resource"


def _header_present(headers, name: str) -> bool:
    if headers is None:
        return False
    getter = getattr(headers, "get", None)
    if callable(getter):
        value = getter(name)
        if value is not None and str(value) != "":
            return True
    # case-insensitive fallback for plain dicts
    if isinstance(headers, dict):
        lower = name.lower()
        for key, value in headers.items():
            if str(key).lower() == lower and value is not None and str(value) != "":
                return True
    return False


def _identity_sources_present(context, authorizer: dict) -> bool:
    raw = str(authorizer.get("identitySource") or "").strip()
    if not raw:
        return True
    request = context.invocation_request or {}
    headers = request.get("headers") or {}
    query = request.get("query_string_parameters") or {}
    path_params = request.get("path_parameters") or {}
    stage_vars = context.stage_variables or {}
    for part in raw.split(","):
        source = part.strip()
        if not source:
            continue
        if source.startswith("method.request.header."):
            if not _header_present(headers, source[len("method.request.header.") :]):
                return False
        elif source.startswith("method.request.querystring."):
            name = source[len("method.request.querystring.") :]
            value = query.get(name) if isinstance(query, dict) else None
            if value is None or str(value) == "":
                return False
        elif source.startswith("method.request.path."):
            name = source[len("method.request.path.") :]
            value = path_params.get(name) if isinstance(path_params, dict) else None
            if value is None or str(value) == "":
                return False
        elif source.startswith("stageVariables."):
            name = source[len("stageVariables.") :]
            value = stage_vars.get(name) if isinstance(stage_vars, dict) else None
            if value is None or str(value) == "":
                return False
        # context.identity.sourceIp is always present on a real request
    return True


def _install() -> None:
    from localemu.services.apigateway.next_gen.execute_api.gateway_response import (
        AccessDeniedError,
        UnauthorizedError,
    )
    from localemu.services.apigateway.next_gen.execute_api.handlers.authorizer import (
        AuthorizerHandler,
    )

    if getattr(AuthorizerHandler, "_awsbox_deny_403", False):
        return

    orig_request = AuthorizerHandler._invoke_request_authorizer
    orig_apply = AuthorizerHandler._apply_authorizer_result

    def _invoke_request_authorizer(self, context, authorizer):
        if not _identity_sources_present(context, authorizer):
            raise UnauthorizedError("Unauthorized")
        return orig_request(self, context, authorizer)

    def _apply_authorizer_result(self, context, result):
        try:
            return orig_apply(self, context, result)
        except UnauthorizedError as exc:
            msg = getattr(exc, "message", None) or str(exc)
            if _DENY_MSG in msg:
                raise AccessDeniedError(_DENY_MSG) from exc
            raise

    AuthorizerHandler._invoke_request_authorizer = _invoke_request_authorizer
    AuthorizerHandler._apply_authorizer_result = _apply_authorizer_result
    AuthorizerHandler._awsbox_deny_403 = True
    LOG.info("awsbox REST authorizer Deny→403 / missing identity→401 applied")


_install()
