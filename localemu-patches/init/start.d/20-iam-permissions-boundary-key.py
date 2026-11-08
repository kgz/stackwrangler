"""Set iam:PermissionsBoundary and iam:PolicyARN request condition keys.

#525 — Deploy-role policies commonly allow iam:CreateRole / PutRolePolicy /
AttachRolePolicy only when Condition StringEquals iam:PermissionsBoundary
matches a fixed boundary ARN. AWS puts that key in the request context;
stock LocalEmu did not, so the Allow never matched.

#648 — Attach/Detach*Policy statements often also ArnEquals iam:PolicyARN to
the one managed policy the deployer may attach. Same gap: key missing from
request context until this patch copies PolicyArn from the request.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.iam_permissions_boundary_key")

# CreateRole: key = PermissionsBoundary on the request.
_REQUEST_BOUNDARY_OPS = frozenset({"CreateRole"})
# Role-policy mutations: key = the target role's current boundary ARN.
_ROLE_BOUNDARY_OPS = frozenset(
    {
        "PutRolePolicy",
        "AttachRolePolicy",
        "DetachRolePolicy",
        "DeleteRolePolicy",
    }
)
# Attach/Detach managed policies: iam:PolicyARN = request PolicyArn (#648).
_POLICY_ARN_OPS = frozenset(
    {
        "AttachRolePolicy",
        "DetachRolePolicy",
        "AttachUserPolicy",
        "DetachUserPolicy",
        "AttachGroupPolicy",
        "DetachGroupPolicy",
    }
)


def _extract_boundary_arn(value) -> str | None:
    if not value:
        return None
    if isinstance(value, str):
        return value or None
    if isinstance(value, dict):
        return value.get("PermissionsBoundaryArn") or value.get("PolicyArn") or None
    return None


def _role_boundary_arn(account_id: str, role_name: str) -> str | None:
    try:
        from moto.iam.models import iam_backends

        backend = iam_backends[account_id]["global"]
        role = backend.get_role(role_name) if hasattr(backend, "get_role") else None
        if role is None:
            return None
        raw = getattr(role, "permissions_boundary_arn", None) or getattr(
            role, "permissions_boundary", None
        )
        return _extract_boundary_arn(raw)
    except Exception:
        LOG.debug(
            "iam:PermissionsBoundary role lookup failed for %s", role_name, exc_info=True
        )
        return None


def _install() -> None:
    from localemu.services.iam_enforcement import enforcer as enforcer_mod

    if getattr(enforcer_mod._build_conditions, "_awsbox_permissions_boundary", False):
        return

    orig = enforcer_mod._build_conditions

    def _build_conditions(context, caller):
        conditions = orig(context, caller)
        try:
            service = getattr(getattr(context, "service", None), "service_name", None)
            operation = getattr(getattr(context, "operation", None), "name", None)
            if service != "iam" or not operation:
                return conditions
            params = context.service_request or {}
            account_id = context.account_id or caller.account_id or "000000000000"
            boundary = None
            if operation in _REQUEST_BOUNDARY_OPS:
                boundary = _extract_boundary_arn(params.get("PermissionsBoundary"))
            elif operation in _ROLE_BOUNDARY_OPS:
                role_name = params.get("RoleName")
                if isinstance(role_name, str) and role_name:
                    boundary = _role_boundary_arn(account_id, role_name)
            if boundary:
                conditions["iam:PermissionsBoundary"] = boundary
            if operation in _POLICY_ARN_OPS:
                policy_arn = params.get("PolicyArn")
                if isinstance(policy_arn, str) and policy_arn:
                    conditions["iam:PolicyARN"] = policy_arn
        except Exception:
            LOG.debug("iam:PermissionsBoundary/PolicyARN context failed", exc_info=True)
        return conditions

    _build_conditions._awsbox_permissions_boundary = True
    enforcer_mod._build_conditions = _build_conditions
    LOG.info("awsbox iam:PermissionsBoundary + iam:PolicyARN condition keys applied")


_install()
