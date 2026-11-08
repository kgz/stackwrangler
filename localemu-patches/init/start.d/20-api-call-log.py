"""Wire per-workload API call log + GET /_awsl/calls (#194)."""

from __future__ import annotations

import json
import logging
import sys
from typing import Any

LOG = logging.getLogger("localemu.awsbox.api_call_log")

_EXEMPT_ACTIONS = frozenset({"sts:GetCallerIdentity"})


def _ensure_import_path() -> None:
    for path in (
        "/opt/code/localemu/src/localemu/services/iam_enforcement",
        "/opt/awsbox",
    ):
        if path not in sys.path:
            sys.path.insert(0, path)


def _load_call_log():
    _ensure_import_path()
    try:
        import api_call_log as mod  # type: ignore
        return mod
    except ImportError:
        # Mounted next to enforcer patches
        import importlib.util
        from pathlib import Path

        for candidate in (
            Path("/opt/code/localemu/src/localemu/services/iam_enforcement/api_call_log.py"),
            Path("/opt/awsbox/api_call_log.py"),
        ):
            if candidate.is_file():
                spec = importlib.util.spec_from_file_location("api_call_log", candidate)
                if spec and spec.loader:
                    mod = importlib.util.module_from_spec(spec)
                    spec.loader.exec_module(mod)
                    sys.modules["api_call_log"] = mod
                    return mod
        raise


def _extract_access_key(context) -> str | None:
    auth = ""
    try:
        auth = context.request.headers.get("Authorization", "") or ""
    except Exception:
        auth = ""
    if auth.startswith("AWS4-HMAC-SHA256"):
        # Credential=AKID/date/region/service/aws4_request
        for part in auth.split(", "):
            part = part.strip()
            if part.startswith("Credential="):
                cred = part[len("Credential=") :]
                return cred.split("/", 1)[0] or None
    if "Credential=" in auth:
        try:
            return auth.split("Credential=", 1)[1].split("/", 1)[0] or None
        except Exception:
            pass
    try:
        from urllib.parse import parse_qs, urlparse

        qs = parse_qs(urlparse(context.request.url).query)
        for key in ("X-Amz-Credential", "AWSAccessKeyId"):
            if key in qs and qs[key]:
                return str(qs[key][0]).split("/", 1)[0]
    except Exception:
        pass
    return None


def _is_internal(context, access_key: str | None) -> bool:
    if getattr(context, "internal_request_params", None):
        return True
    if access_key == "__internal_call__":
        return True
    try:
        if context.request.headers.get("x-localemu-data"):
            return True
    except Exception:
        pass
    return False


def _resource_ids(params: Any) -> list[str]:
    """Keep resource identifiers only — never secret values / bodies."""
    if not isinstance(params, dict):
        return []
    keys = (
        "SecretId",
        "Name",
        "Arn",
        "ResourceArn",
        "Resource",
        "RoleArn",
        "FunctionName",
        "QueueUrl",
        "TopicArn",
        "Bucket",
        "Key",
        "TableName",
        "StreamName",
        "KeyId",
        "TargetArn",
        "Cluster",
        "TaskDefinition",
        "StackName",
        "DBInstanceIdentifier",
        "LogGroupName",
    )
    out: list[str] = []
    for key in keys:
        val = params.get(key)
        if isinstance(val, str) and val.strip():
            out.append(val.strip())
        elif isinstance(val, list):
            for item in val:
                if isinstance(item, str) and item.strip():
                    out.append(item.strip())
    return out


def _iam_checks(context) -> tuple[str, list[str], list[tuple[str, str]]]:
    from localemu.services.iam_enforcement.arn_builder import build_resource_arn
    from localemu.services.iam_enforcement.service_action_map import (
        expand_permission_checks,
        map_action,
    )

    service_name = context.service.service_name
    region = context.region or "us-east-1"
    account_id = context.account_id or "000000000000"
    checks = expand_permission_checks(
        service_name,
        context.operation.name,
        context.service_request,
        region,
        account_id,
        build_resource_arn,
    )
    if not checks:
        actions = map_action(service_name, context.operation.name)
        arn = build_resource_arn(
            service=service_name,
            operation=context.operation.name,
            request_params=context.service_request,
            region=region,
            account_id=account_id,
        )
        checks = [(a, arn) for a in actions]
    action = checks[0][0] if checks else f"{service_name}:{context.operation.name}"
    resources = []
    for _a, arn in checks:
        if arn and arn not in resources:
            resources.append(arn)
    for rid in _resource_ids(context.service_request):
        if rid not in resources:
            resources.append(rid)
    return action, resources, checks


def _deny_reason(caller, action: str, resource: str, decision) -> str:
    from localemu.services.iam_enforcement.evaluator import Decision

    if decision == Decision.EXPLICIT_DENY:
        policy = _find_explicit_deny_policy(caller, action, resource)
        if policy:
            return f"explicit deny by {policy}"
        return "explicit deny"
    return "no allowing policy"


def _find_explicit_deny_policy(caller, action: str, resource: str) -> str | None:
    """Best-effort name/Sid of an identity Deny that matched."""
    try:
        from localemu.services.iam_enforcement.action_matcher import matches_action
        from localemu.services.iam_enforcement.condition_evaluator import matches_conditions
        from localemu.services.iam_enforcement.identity import get_identity_policies
        from localemu.services.iam_enforcement.resource_matcher import matches_resource
        from moto.iam.models import iam_backends
    except Exception:
        return None

    try:
        backend = iam_backends[caller.account_id]["global"]
    except Exception:
        backend = None

    named: list[tuple[str, dict]] = []
    try:
        if caller.principal_type == "AssumedRole" and caller.role_name and backend:
            role = None
            for r in backend.roles.values():
                if r.name == caller.role_name:
                    role = r
                    break
            if role:
                for name, doc in (role.policies or {}).items():
                    if isinstance(doc, str):
                        try:
                            doc = json.loads(doc)
                        except Exception:
                            continue
                    if isinstance(doc, dict):
                        named.append((f"inline:{name}", doc))
                for arn in (role.managed_policies or {}):
                    named.append((f"managed:{arn.rsplit('/', 1)[-1]}", {"Statement": []}))
        for policy in get_identity_policies(caller):
            if not isinstance(policy, dict):
                continue
            named.append(("identity-policy", policy))
    except Exception:
        return None

    conditions = {}
    for name, policy in named:
        stmts = policy.get("Statement") or []
        if isinstance(stmts, dict):
            stmts = [stmts]
        for stmt in stmts:
            if not isinstance(stmt, dict) or stmt.get("Effect") != "Deny":
                continue
            try:
                if not matches_action(stmt, action):
                    continue
                if not matches_resource(stmt, resource, conditions):
                    continue
                if not matches_conditions(stmt, conditions):
                    continue
            except Exception:
                continue
            sid = stmt.get("Sid")
            if sid:
                return f"{name} (Sid={sid})"
            return name
    return None


def _resolve_caller(context, access_key: str | None):
    if not access_key:
        return None
    try:
        from localemu.services.iam_enforcement.identity import resolve_caller

        return resolve_caller(
            access_key,
            context.account_id or "000000000000",
            context.region or "us-east-1",
        )
    except Exception:
        return None


def _record(
    call_log,
    context,
    *,
    result: str,
    reason: str | None,
    action: str,
    resources: list[str],
    caller,
):
    if action in _EXEMPT_ACTIONS:
        return
    access_key = _extract_access_key(context)
    if _is_internal(context, access_key):
        return

    if caller is None:
        caller_arn = "unknown"
        workload = "unknown"
    else:
        if getattr(caller, "principal_type", None) == "Anonymous":
            return
        caller_arn = getattr(caller, "arn", None) or "unknown"
        workload = call_log.workload_id_for_caller(caller)

    request_id = getattr(context, "request_id", None)
    if request_id is not None:
        request_id = str(request_id)

    service = ""
    try:
        service = context.service.service_name
    except Exception:
        service = action.split(":", 1)[0] if ":" in action else ""

    call_log.record(
        caller=caller_arn,
        workload=workload,
        service=service,
        action=action,
        resources=resources,
        result=result,
        reason=reason,
        request_id=request_id,
    )


def _install_http(call_log) -> None:
    from localemu.http import Request, Resource
    from localemu.services.internal import get_internal_apis

    class CallsResource:
        def on_get(self, request: Request):
            raw_qs = getattr(request, "query_string", b"") or b""
            if isinstance(raw_qs, bytes):
                qs = raw_qs.decode()
            else:
                qs = str(raw_qs)
            params = call_log.parse_query_params(qs)
            try:
                limit = int(params.get("limit") or "500")
            except ValueError:
                limit = 500
            records = call_log.query(
                workload=params.get("workload") or None,
                service=params.get("service") or None,
                action=params.get("action") or None,
                result=params.get("result") or None,
                since=params.get("since") or None,
                limit=limit,
            )
            return {"calls": [r.to_dict() for r in records]}

        def on_delete(self, request: Request):
            call_log.clear()
            return {"cleared": True}

    router = get_internal_apis()
    router.add(Resource("/_awsl/calls", CallsResource()))
    LOG.info("GET /_awsl/calls registered")


def _install_enforcer_hook(call_log) -> None:
    from localemu.aws.api import CommonServiceException
    from localemu.services.iam_enforcement import enforcer
    from localemu.services.iam_enforcement.evaluator import Decision

    orig = enforcer.IAMEnforcementHandler.__call__
    if getattr(enforcer.IAMEnforcementHandler, "_awsbox_call_log", False):
        return

    def __call__(self, chain, context, response):
        if not context.service or not context.operation:
            return orig(self, chain, context, response)

        access_key = _extract_access_key(context)
        if _is_internal(context, access_key):
            return orig(self, chain, context, response)

        try:
            action, resources, _checks = _iam_checks(context)
        except Exception as exc:
            LOG.debug("call log: failed to map action: %s", exc)
            return orig(self, chain, context, response)

        if action in _EXEMPT_ACTIONS:
            return orig(self, chain, context, response)

        caller = _resolve_caller(context, access_key)
        last_decision = {"value": None}

        orig_evaluate = self.evaluator.evaluate

        def tracking_evaluate(*args, **kwargs):
            decision = orig_evaluate(*args, **kwargs)
            last_decision["value"] = decision
            return decision

        self.evaluator.evaluate = tracking_evaluate
        try:
            try:
                orig(self, chain, context, response)
            except CommonServiceException as exc:
                code = getattr(exc, "code", None) or ""
                if "AccessDenied" in str(code) or "AccessDenied" in str(exc):
                    decision = last_decision["value"]
                    reason = None
                    if decision is not None and caller is not None:
                        reason = _deny_reason(
                            caller,
                            action,
                            resources[0] if resources else "*",
                            decision,
                        )
                    else:
                        reason = getattr(exc, "message", None) or "AccessDenied"
                    _record(
                        call_log,
                        context,
                        result="denied",
                        reason=reason,
                        action=action,
                        resources=resources,
                        caller=caller,
                    )
                raise
            else:
                # Soft-mode deny still returns without raising — honour decision.
                decision = last_decision["value"]
                if decision is not None and decision != Decision.ALLOW:
                    reason = (
                        _deny_reason(
                            caller,
                            action,
                            resources[0] if resources else "*",
                            decision,
                        )
                        if caller is not None
                        else "denied"
                    )
                    _record(
                        call_log,
                        context,
                        result="denied",
                        reason=reason,
                        action=action,
                        resources=resources,
                        caller=caller,
                    )
                else:
                    _record(
                        call_log,
                        context,
                        result="allowed",
                        reason=None,
                        action=action,
                        resources=resources,
                        caller=caller,
                    )
        finally:
            self.evaluator.evaluate = orig_evaluate

    enforcer.IAMEnforcementHandler.__call__ = __call__
    enforcer.IAMEnforcementHandler._awsbox_call_log = True
    LOG.info("IAM enforcer call-log hook applied")


def _install() -> None:
    call_log = _load_call_log()
    _install_http(call_log)
    _install_enforcer_hook(call_log)
    LOG.info("api call log ready (#194)")


_install()
