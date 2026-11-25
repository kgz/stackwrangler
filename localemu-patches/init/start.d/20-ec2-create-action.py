"""Implicit ec2:CreateTags with ec2:CreateAction on tag-on-create (#669).

Real deploy-role policies often Allow ``ec2:CreateTags`` only when
``ec2:CreateAction`` is the parent create API (e.g. CreateSecurityGroup).
AWS evaluates that CreateTags check when TagSpecifications are present;
standalone CreateTags does not set CreateAction.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.ec2_create_action")

# TagSpecification ResourceType → EC2 ARN resource-id prefix.
_RESOURCE_TYPE_PREFIX = {
    "security-group": "security-group",
    "vpc": "vpc",
    "subnet": "subnet",
    "network-interface": "network-interface",
    "instance": "instance",
    "volume": "volume",
    "snapshot": "snapshot",
    "image": "image",
    "route-table": "route-table",
    "internet-gateway": "internet-gateway",
    "natgateway": "natgateway",
    "elastic-ip": "elastic-ip",
    "dhcp-options": "dhcp-options",
    "placement-group": "placement-group",
    "key-pair": "key-pair",
    "launch-template": "launch-template",
    "fleet": "fleet",
    "spot-instances-request": "spot-instances-request",
    "spot-fleet-request": "spot-fleet-request",
    "capacity-reservation": "capacity-reservation",
    "carrier-gateway": "carrier-gateway",
    "transit-gateway": "transit-gateway",
    "vpc-endpoint": "vpc-endpoint",
}


def _tag_specs(params: dict) -> list[dict]:
    specs = params.get("TagSpecifications") or params.get("TagSpecification") or []
    if isinstance(specs, dict):
        specs = [specs]
    if not isinstance(specs, list):
        return []
    return [s for s in specs if isinstance(s, dict)]


def _spec_has_tags(spec: dict) -> bool:
    from localemu.services.iam_enforcement.resource_tag_loader import (
        _normalize_tag_list,
    )

    tags = spec.get("Tags") or spec.get("tags") or []
    return bool(_normalize_tag_list(tags))


def _resource_arns_for_specs(
    specs: list[dict], region: str, account_id: str
) -> list[str]:
    arns: list[str] = []
    seen: set[str] = set()
    for spec in specs:
        if not _spec_has_tags(spec):
            continue
        raw = spec.get("ResourceType") or spec.get("resourceType") or ""
        if not isinstance(raw, str) or not raw:
            continue
        prefix = _RESOURCE_TYPE_PREFIX.get(raw.lower().replace("_", "-"))
        if not prefix:
            continue
        arn = f"arn:aws:ec2:{region}:{account_id}:{prefix}/*"
        if arn not in seen:
            seen.add(arn)
            arns.append(arn)
    return arns


def _patch_create_action_create_tags() -> None:
    from localemu.aws.api import CommonServiceException
    from localemu.services.iam_enforcement.enforcer import IAMEnforcementHandler
    from localemu.services.iam_enforcement.evaluator import Decision
    from localemu.services.iam_enforcement.identity import resolve_caller
    from localemu.services.iam_enforcement import enforcer as enforcer_mod

    if getattr(IAMEnforcementHandler, "_awsbox_ec2_create_action", False):
        return

    original_call = IAMEnforcementHandler.__call__

    def _enforce_create_tags_on_create(self, context) -> None:
        _enforce, audit, enabled = self._read_mode()
        if not enabled or not context.service or not context.operation:
            return
        if context.service.service_name != "ec2":
            return
        operation = context.operation.name
        # Tag-on-create only: parent Create* APIs, not CreateTags itself.
        if not operation.startswith("Create") or operation in (
            "CreateTags",
            "CreateDefaultVpc",
            "CreateDefaultSubnet",
        ):
            return
        params = context.service_request or {}
        specs = _tag_specs(params)
        if not any(_spec_has_tags(s) for s in specs):
            return

        access_key = enforcer_mod._extract_access_key(context)
        if self._is_internal_call(context, access_key) or not access_key:
            return
        account_id = context.account_id or "000000000000"
        caller = resolve_caller(access_key, account_id, context.region)
        if not caller or caller.principal_type == "Root":
            return

        region = context.region or "us-east-1"
        resource_arns = _resource_arns_for_specs(specs, region, account_id)
        if not resource_arns:
            # Tagged specs with unknown ResourceType — still gate CreateTags
            # on a wildcard so CreateAction policies are evaluated.
            resource_arns = [f"arn:aws:ec2:{region}:{account_id}:*"]

        base = enforcer_mod._build_conditions(context, caller)
        conditions = dict(base)
        conditions["ec2:CreateAction"] = operation

        for resource_arn in resource_arns:
            decision = self.evaluator.evaluate(
                caller=caller,
                action="ec2:CreateTags",
                resource=resource_arn,
                conditions=conditions,
                resource_policy=None,
            )
            if decision == Decision.ALLOW:
                continue
            message = (
                f"User: {caller.arn} is not authorized to perform: "
                f"ec2:CreateTags on resource: {resource_arn}"
            )
            if audit:
                LOG.warning("IAM AUDIT DENY: %s", message)
                return
            raise CommonServiceException(
                code="AccessDenied",
                message=message,
                status_code=403,
                sender_fault=True,
            )

    def __call__(self, chain, context, response):
        original_call(self, chain, context, response)
        _enforce_create_tags_on_create(self, context)

    IAMEnforcementHandler.__call__ = __call__
    IAMEnforcementHandler._awsbox_ec2_create_action = True
    LOG.info("awsbox ec2:CreateAction tag-on-create CreateTags applied")


_patch_create_action_create_tags()
