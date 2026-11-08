"""Wire per-workload API call log + GET /_awsl/calls (#194)."""

from __future__ import annotations

import json
import logging
import sys
import threading
from typing import Any

LOG = logging.getLogger("localemu.awsbox.api_call_log")

_EXEMPT_ACTIONS = frozenset({"sts:GetCallerIdentity"})

# Last PolicyEvaluator.evaluate decision for this thread (install wraps once).
_tls = threading.local()


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


def _named_identity_policies(caller) -> list[tuple[str, dict]]:
    """Inline/managed identity policies with a stable display name."""
    named: list[tuple[str, dict]] = []
    try:
        from moto.iam.models import iam_backends

        backend = iam_backends[caller.account_id]["global"]
    except Exception:
        return named

    role = None
    if caller.principal_type == "AssumedRole" and caller.role_name:
        for r in backend.roles.values():
            if r.name == caller.role_name:
                role = r
                break
        if role:
            for name, doc in (role.policies or {}).items():
                parsed = _parse_policy_doc(doc)
                if parsed is not None:
                    named.append((f"inline:{name}", parsed))
            for arn, policy in (role.managed_policies or {}).items():
                parsed = _managed_policy_doc(backend, arn, policy)
                if parsed is not None:
                    named.append((f"managed:{str(arn).rsplit('/', 1)[-1]}", parsed))
    elif caller.principal_type == "User" and caller.username:
        user = backend.users.get(caller.username)
        if user:
            for name, doc in (user.policies or {}).items():
                parsed = _parse_policy_doc(doc)
                if parsed is not None:
                    named.append((f"inline:{name}", parsed))
            for arn, policy in (user.managed_policies or {}).items():
                parsed = _managed_policy_doc(backend, arn, policy)
                if parsed is not None:
                    named.append((f"managed:{str(arn).rsplit('/', 1)[-1]}", parsed))
    return named


def _parse_policy_doc(doc) -> dict | None:
    if isinstance(doc, dict):
        return doc
    if isinstance(doc, str):
        try:
            parsed = json.loads(doc)
        except Exception:
            return None
        return parsed if isinstance(parsed, dict) else None
    return None


def _managed_policy_doc(backend, arn, policy) -> dict | None:
    try:
        from localemu.services.iam_enforcement.identity import _get_managed_policy_doc

        doc = _get_managed_policy_doc(backend, arn)
        if isinstance(doc, dict):
            return doc
    except Exception:
        pass
    return _parse_policy_doc(getattr(policy, "policy_document", None) or getattr(policy, "document", None))


def _find_explicit_deny_policy(caller, action: str, resource: str) -> str | None:
    """Best-effort name/Sid of an identity Deny that matched."""
    try:
        from localemu.services.iam_enforcement.action_matcher import matches_action
        from localemu.services.iam_enforcement.condition_evaluator import matches_conditions
        from localemu.services.iam_enforcement.resource_matcher import matches_resource
    except Exception:
        return None

    conditions: dict = {}
    for name, policy in _named_identity_policies(caller):
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
    enforcer,
):
    if action in _EXEMPT_ACTIONS:
        return
    access_key = enforcer._extract_access_key(context)
    if enforcer.IAMEnforcementHandler._is_internal_call(context, access_key):
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


def _install_evaluate_tracker() -> None:
    """Wrap PolicyEvaluator.evaluate once; stash decision in thread-local."""
    from localemu.services.iam_enforcement.evaluator import PolicyEvaluator

    if getattr(PolicyEvaluator, "_awsbox_call_log_tracked", False):
        return

    orig_evaluate = PolicyEvaluator.evaluate

    def evaluate(self, *args, **kwargs):
        decision = orig_evaluate(self, *args, **kwargs)
        _tls.last_decision = decision
        return decision

    PolicyEvaluator.evaluate = evaluate
    PolicyEvaluator._awsbox_call_log_tracked = True
    LOG.info("PolicyEvaluator.evaluate call-log tracker applied")


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

        access_key = enforcer._extract_access_key(context)
        if self._is_internal_call(context, access_key):
            return orig(self, chain, context, response)

        try:
            action, resources, _checks = _iam_checks(context)
        except Exception as exc:
            LOG.debug("call log: failed to map action: %s", exc)
            return orig(self, chain, context, response)

        if action in _EXEMPT_ACTIONS:
            return orig(self, chain, context, response)

        caller = _resolve_caller(context, access_key)
        _tls.last_decision = None
        try:
            orig(self, chain, context, response)
        except CommonServiceException as exc:
            code = getattr(exc, "code", None) or ""
            if "AccessDenied" in str(code) or "AccessDenied" in str(exc):
                decision = getattr(_tls, "last_decision", None)
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
                    enforcer=enforcer,
                )
            raise
        else:
            # Soft-mode deny still returns without raising — honour decision.
            decision = getattr(_tls, "last_decision", None)
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
                    enforcer=enforcer,
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
                    enforcer=enforcer,
                )

    enforcer.IAMEnforcementHandler.__call__ = __call__
    enforcer.IAMEnforcementHandler._awsbox_call_log = True
    LOG.info("IAM enforcer call-log hook applied")


def _install() -> None:
    call_log = _load_call_log()
    _install_http(call_log)
    _install_evaluate_tracker()
    _install_enforcer_hook(call_log)
    LOG.info("api call log ready (#194)")


_install()
