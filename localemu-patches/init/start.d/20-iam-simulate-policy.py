"""Wire iam:SimulateCustomPolicy / SimulatePrincipalPolicy to the enforcer evaluator.

Stock LocalEmu raises NotImplementedError for SimulateCustomPolicy, and
SimulatePrincipalPolicy uses a separate fnmatch simulator that ignores
conditions, boundaries, and resource policies. We evaluate with the same
matchers / algorithm as ``PolicyEvaluator`` so simulator answers match
enforcement. Real AWS's IAM policy simulator has its own quirks for some
resource-scoped actions — we deliberately match the enforcer, not those.
"""

from __future__ import annotations

import json
import logging
from typing import Any

LOG = logging.getLogger("localemu.awsbox.iam_simulate_policy")

_DECISION_TO_EVAL = {
    "ALLOW": "allowed",
    "EXPLICIT_DENY": "explicitDeny",
    "IMPLICIT_DENY": "implicitDeny",
}


def _parse_policy(doc: Any) -> dict | None:
    if doc is None:
        return None
    if isinstance(doc, dict):
        return doc
    if isinstance(doc, str):
        try:
            parsed = json.loads(doc)
        except (json.JSONDecodeError, TypeError):
            LOG.warning("iam simulate: failed to parse policy document")
            return None
        return parsed if isinstance(parsed, dict) else None
    LOG.warning("iam simulate: unexpected policy type %s", type(doc))
    return None


def _parse_policy_list(docs: list | None) -> list[dict]:
    out: list[dict] = []
    for doc in docs or []:
        parsed = _parse_policy(doc)
        if parsed is not None:
            out.append(parsed)
    return out


def _context_from_entries(entries: list | None) -> dict[str, Any]:
    ctx: dict[str, Any] = {}
    for entry in entries or []:
        if not isinstance(entry, dict):
            continue
        name = entry.get("ContextKeyName")
        if not name:
            continue
        values = entry.get("ContextKeyValues") or []
        key_type = entry.get("ContextKeyType") or "string"
        if key_type.endswith("List") or len(values) > 1:
            ctx[name] = list(values)
        elif values:
            ctx[name] = values[0]
    return ctx


def _strip_set_prefix(operator: str) -> tuple[str, str | None]:
    if operator.startswith("ForAllValues:"):
        return operator[len("ForAllValues:") :], "all"
    if operator.startswith("ForAnyValue:"):
        return operator[len("ForAnyValue:") :], "any"
    return operator, None


def _missing_context_keys(statement: dict, context: dict) -> list[str]:
    """Condition keys referenced by a statement that are absent from context."""
    conditions = statement.get("Condition")
    if not conditions or not isinstance(conditions, dict):
        return []
    missing: list[str] = []
    for operator, block in conditions.items():
        if not isinstance(block, dict):
            continue
        if_exists = operator.endswith("IfExists")
        base = operator[: -len("IfExists")] if if_exists else operator
        base, _ = _strip_set_prefix(base)
        if if_exists or base == "Null":
            continue
        for key in block:
            value = context.get(key)
            if isinstance(value, list) and len(value) == 0:
                value = None
            if value is None and key not in missing:
                missing.append(key)
    return missing


def _matched_statement(
    policy_id: str, policy_type: str
) -> dict[str, str]:
    return {
        "SourcePolicyId": policy_id,
        "SourcePolicyType": policy_type,
    }


def _synthetic_caller(account_id: str, caller_arn: str | None):
    from localemu.services.iam_enforcement.identity import CallerIdentity

    arn = caller_arn or f"arn:aws:iam::{account_id}:user/SimulatePolicyUser"
    principal_type = "User"
    username = None
    role_name = None
    if arn.endswith(":root") or ":root" == arn.split(":")[-1]:
        principal_type = "Root"
    elif ":assumed-role/" in arn:
        principal_type = "AssumedRole"
        parts = arn.split(":assumed-role/")[-1].split("/")
        role_name = parts[0] if parts else None
    elif ":role/" in arn:
        # Identity policies are injected; keep non-Root so we evaluate them.
        principal_type = "User"
        role_name = arn.split("/")[-1]
    elif ":user/" in arn:
        username = arn.split("/")[-1]
    return CallerIdentity(
        principal_type=principal_type,
        account_id=account_id,
        arn=arn,
        username=username,
        role_name=role_name,
    )


def _evaluate_one(
    *,
    action: str,
    resource: str,
    identity_policies: list[tuple[str, str, dict]],
    permission_boundaries: list[tuple[str, str, dict]],
    resource_policy: tuple[str, str, dict] | None,
    conditions: dict[str, Any],
    caller,
) -> dict:
    """Mirror ``PolicyEvaluator.evaluate`` and enrich with MatchedStatements."""
    from localemu.services.iam_enforcement.action_matcher import matches_action
    from localemu.services.iam_enforcement.condition_evaluator import matches_conditions
    from localemu.services.iam_enforcement.evaluator import (
        Decision,
        _matches_principal,
    )
    from localemu.services.iam_enforcement.resource_matcher import matches_resource
    from localemu.utils.aws.policy import iter_policy_statements

    merged = {**conditions, **(caller.tags or {})}
    missing: list[str] = []

    def _scan_missing(stmt: dict) -> None:
        for key in _missing_context_keys(stmt, merged):
            if key not in missing:
                missing.append(key)

    # Root bypass matches enforcer (admin / root keys).
    if caller.principal_type == "Root":
        return {
            "EvalActionName": action,
            "EvalResourceName": resource,
            "EvalDecision": "allowed",
            "MatchedStatements": [],
            "MissingContextValues": missing,
        }

    all_tagged: list[tuple[str, str, dict, bool]] = [
        (pid, ptype, pol, False) for pid, ptype, pol in identity_policies
    ]
    if resource_policy is not None:
        all_tagged.append((*resource_policy, True))
    for pid, ptype, pol in permission_boundaries:
        all_tagged.append((pid, ptype, pol, False))

    # 1) Explicit Deny anywhere
    deny_matched: list[dict[str, str]] = []
    for policy_id, policy_type, policy, is_resource in all_tagged:
        for idx, statement in enumerate(iter_policy_statements(policy)):
            if statement.get("Effect") != "Deny":
                continue
            if not matches_action(statement, action):
                continue
            if not matches_resource(statement, resource, merged):
                continue
            if is_resource and not _matches_principal(statement, caller):
                continue
            _scan_missing(statement)
            if not matches_conditions(statement, merged):
                continue
            sid = statement.get("Sid") or f"{policy_id}.Statement[{idx}]"
            deny_matched.append(_matched_statement(str(sid), policy_type))
    if deny_matched:
        return {
            "EvalActionName": action,
            "EvalResourceName": resource,
            "EvalDecision": _DECISION_TO_EVAL[Decision.EXPLICIT_DENY.value],
            "MatchedStatements": deny_matched,
            "MissingContextValues": missing,
        }

    # 2) Resource-policy Allow (same-account short-circuit, same as enforcer)
    if resource_policy is not None:
        policy_id, policy_type, policy = resource_policy
        allow_matched: list[dict[str, str]] = []
        for idx, statement in enumerate(iter_policy_statements(policy)):
            if statement.get("Effect") != "Allow":
                continue
            if not _matches_principal(statement, caller):
                continue
            if not matches_action(statement, action):
                continue
            if not matches_resource(statement, resource, merged):
                continue
            _scan_missing(statement)
            if not matches_conditions(statement, merged):
                continue
            sid = statement.get("Sid") or f"{policy_id}.Statement[{idx}]"
            allow_matched.append(_matched_statement(str(sid), policy_type))
        if allow_matched:
            return {
                "EvalActionName": action,
                "EvalResourceName": resource,
                "EvalDecision": _DECISION_TO_EVAL[Decision.ALLOW.value],
                "MatchedStatements": allow_matched,
                "MissingContextValues": missing,
            }

    # 3) Identity Allow
    identity_matched: list[dict[str, str]] = []
    for policy_id, policy_type, policy in identity_policies:
        for idx, statement in enumerate(iter_policy_statements(policy)):
            if statement.get("Effect") != "Allow":
                continue
            if not matches_action(statement, action):
                continue
            if not matches_resource(statement, resource, merged):
                continue
            _scan_missing(statement)
            if not matches_conditions(statement, merged):
                continue
            sid = statement.get("Sid") or f"{policy_id}.Statement[{idx}]"
            identity_matched.append(_matched_statement(str(sid), policy_type))

    if not identity_matched:
        return {
            "EvalActionName": action,
            "EvalResourceName": resource,
            "EvalDecision": _DECISION_TO_EVAL[Decision.IMPLICIT_DENY.value],
            "MatchedStatements": [],
            "MissingContextValues": missing,
        }

    # 4) Permission boundary must also Allow when present
    if permission_boundaries:
        boundary_matched: list[dict[str, str]] = []
        for policy_id, policy_type, policy in permission_boundaries:
            for idx, statement in enumerate(iter_policy_statements(policy)):
                if statement.get("Effect") != "Allow":
                    continue
                if not matches_action(statement, action):
                    continue
                if not matches_resource(statement, resource, merged):
                    continue
                _scan_missing(statement)
                if not matches_conditions(statement, merged):
                    continue
                sid = statement.get("Sid") or f"{policy_id}.Statement[{idx}]"
                boundary_matched.append(_matched_statement(str(sid), policy_type))
        if not boundary_matched:
            return {
                "EvalActionName": action,
                "EvalResourceName": resource,
                "EvalDecision": _DECISION_TO_EVAL[Decision.IMPLICIT_DENY.value],
                "MatchedStatements": identity_matched,
                "MissingContextValues": missing,
            }
        return {
            "EvalActionName": action,
            "EvalResourceName": resource,
            "EvalDecision": _DECISION_TO_EVAL[Decision.ALLOW.value],
            "MatchedStatements": identity_matched + boundary_matched,
            "MissingContextValues": missing,
        }

    return {
        "EvalActionName": action,
        "EvalResourceName": resource,
        "EvalDecision": _DECISION_TO_EVAL[Decision.ALLOW.value],
        "MatchedStatements": identity_matched,
        "MissingContextValues": missing,
    }


def _tag_policies(
    policies: list[dict], *, prefix: str, policy_type: str
) -> list[tuple[str, str, dict]]:
    return [
        (f"{prefix}.{i}", policy_type, policy) for i, policy in enumerate(policies)
    ]


def _simulate(
    *,
    account_id: str,
    action_names: list[str],
    resource_arns: list[str] | None,
    identity_policies: list[tuple[str, str, dict]],
    permission_boundaries: list[tuple[str, str, dict]],
    resource_policy_doc: Any,
    caller_arn: str | None,
    context_entries: list | None,
) -> dict:
    resources = resource_arns or ["*"]
    conditions = _context_from_entries(context_entries)
    caller = _synthetic_caller(account_id, caller_arn)

    rp_parsed = _parse_policy(resource_policy_doc)
    resource_policy = None
    if rp_parsed is not None:
        resource_policy = ("ResourcePolicy", "resource", rp_parsed)

    evaluations = [
        _evaluate_one(
            action=action,
            resource=resource,
            identity_policies=identity_policies,
            permission_boundaries=permission_boundaries,
            resource_policy=resource_policy,
            conditions=conditions,
            caller=caller,
        )
        for action in action_names
        for resource in resources
    ]
    return {"EvaluationResults": evaluations, "IsTruncated": False}


def _principal_identity_policies(backend, principal_arn: str) -> list[tuple[str, str, dict]]:
    """Load attached + inline policies for a user/role/group (same sources as stock simulator)."""
    from localemu.services.iam.resources.policy_simulator import BasicIAMPolicySimulator

    raw = BasicIAMPolicySimulator.get_policies_from_principal(backend, principal_arn)
    tagged: list[tuple[str, str, dict]] = []
    source_type = "user-managed"
    if ":role/" in principal_arn:
        source_type = "role"
    elif ":group/" in principal_arn:
        source_type = "group"
    elif ":user/" in principal_arn:
        source_type = "user"
    for i, doc in enumerate(raw):
        parsed = _parse_policy(doc)
        if parsed is None:
            continue
        tagged.append((f"PrincipalPolicy.{i}", source_type, parsed))
    return tagged


def _principal_permission_boundary(backend, principal_arn: str) -> list[tuple[str, str, dict]]:
    try:
        if ":role/" in principal_arn:
            role_name = principal_arn.split("/")[-1]
            role = backend.roles.get(role_name)
            if role is None:
                return []
            pb_arn = getattr(role, "permissions_boundary", None) or getattr(
                role, "permissions_boundary_arn", None
            )
        elif ":user/" in principal_arn:
            user_name = principal_arn.split("/")[-1]
            user = backend.users.get(user_name)
            if user is None:
                return []
            pb_arn = getattr(user, "permissions_boundary", None) or getattr(
                user, "permissions_boundary_arn", None
            )
        else:
            return []
        if not pb_arn:
            return []
        policy = backend.managed_policies.get(pb_arn)
        if policy is None:
            return []
        parsed = _parse_policy(getattr(policy, "document", None))
        if parsed is None:
            return []
        return [("PermissionsBoundary.0", "user-managed", parsed)]
    except Exception:
        LOG.debug("iam simulate: could not load permission boundary", exc_info=True)
        return []


def _install() -> None:
    from localemu.aws.api import RequestContext
    from localemu.aws.api.iam import (
        SimulatePolicyResponse,
        SimulatePrincipalPolicyRequest,
    )
    from localemu.services.iam.provider import IamProvider
    from localemu.services.iam.resources.policy_simulator import BasicIAMPolicySimulator

    def simulate_custom_policy(
        self,
        context: RequestContext,
        policy_input_list,
        action_names,
        permissions_boundary_policy_input_list=None,
        resource_arns=None,
        resource_policy=None,
        resource_owner=None,
        caller_arn=None,
        context_entries=None,
        resource_handling_option=None,
        max_items=None,
        marker=None,
        **kwargs,
    ) -> SimulatePolicyResponse:
        del self, resource_owner, resource_handling_option, max_items, marker, kwargs
        identity = _tag_policies(
            _parse_policy_list(policy_input_list),
            prefix="PolicyInputList",
            policy_type="user-managed",
        )
        boundaries = _tag_policies(
            _parse_policy_list(permissions_boundary_policy_input_list),
            prefix="PermissionsBoundaryPolicyInputList",
            policy_type="user-managed",
        )
        return _simulate(
            account_id=context.account_id,
            action_names=list(action_names or []),
            resource_arns=list(resource_arns) if resource_arns else None,
            identity_policies=identity,
            permission_boundaries=boundaries,
            resource_policy_doc=resource_policy,
            caller_arn=caller_arn,
            context_entries=context_entries,
        )

    def simulate_principal_policy(
        self,
        context: RequestContext,
        request: SimulatePrincipalPolicyRequest,
    ) -> SimulatePolicyResponse:
        del self
        backend = BasicIAMPolicySimulator.get_iam_backend(context)
        source_arn = request.get("PolicySourceArn") or ""
        identity = _principal_identity_policies(backend, source_arn)
        # Optional extra identity policies from the request
        identity.extend(
            _tag_policies(
                _parse_policy_list(request.get("PolicyInputList")),
                prefix="PolicyInputList",
                policy_type="user-managed",
            )
        )
        boundaries = _tag_policies(
            _parse_policy_list(request.get("PermissionsBoundaryPolicyInputList")),
            prefix="PermissionsBoundaryPolicyInputList",
            policy_type="user-managed",
        )
        if not boundaries:
            boundaries = _principal_permission_boundary(backend, source_arn)
        caller_arn = request.get("CallerArn") or source_arn
        return _simulate(
            account_id=context.account_id,
            action_names=list(request.get("ActionNames") or []),
            resource_arns=list(request.get("ResourceArns") or []) or None,
            identity_policies=identity,
            permission_boundaries=boundaries,
            resource_policy_doc=request.get("ResourcePolicy"),
            caller_arn=caller_arn,
            context_entries=request.get("ContextEntries"),
        )

    # Do not replace IamProvider.simulate_principal_policy — it keeps
    # @handler(expand=False). Patch the simulator method it already calls.
    IamProvider.simulate_custom_policy = simulate_custom_policy
    BasicIAMPolicySimulator.simulate_principal_policy = simulate_principal_policy
    LOG.info("awsbox IAM SimulateCustomPolicy / SimulatePrincipalPolicy wired to enforcer evaluator")


_install()
