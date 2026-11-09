"""Set ec2:Vpc / ec2:ResourceTag/* / TagSpecifications RequestTag keys (#664).

Deploy-role policies commonly scope security groups with ArnEquals
``ec2:Vpc``, ``ec2:ResourceTag/...``, and tag-on-create
``aws:RequestTag/...``. Stock LocalEmu never set those keys, so the
Allows never matched.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.ec2_vpc_condition_keys")


def _vpc_arn(region: str, account_id: str, vpc_id: str) -> str:
    return f"arn:aws:ec2:{region}:{account_id}:vpc/{vpc_id}"


def _sg_ids_from_params(params: dict) -> list[str]:
    ids: list[str] = []
    for key in ("GroupId", "SecurityGroupId"):
        val = params.get(key)
        if isinstance(val, str) and val.startswith("sg-"):
            ids.append(val)
        elif isinstance(val, list):
            for item in val:
                if isinstance(item, str) and item.startswith("sg-"):
                    ids.append(item)
    for key in ("GroupIds", "SecurityGroupIds"):
        val = params.get(key)
        if isinstance(val, list):
            for item in val:
                if isinstance(item, str) and item.startswith("sg-"):
                    ids.append(item)
    resources = params.get("Resources") or params.get("ResourceId") or []
    if isinstance(resources, str):
        resources = [resources]
    if isinstance(resources, list):
        for item in resources:
            if isinstance(item, str) and item.startswith("sg-"):
                ids.append(item)
    # Preserve order, drop dupes.
    seen: set[str] = set()
    out: list[str] = []
    for sg_id in ids:
        if sg_id not in seen:
            seen.add(sg_id)
            out.append(sg_id)
    return out


def _lookup_security_group(account_id: str, region: str, group_id: str):
    try:
        import moto.backends as moto_backends

        backend = moto_backends.get_backend("ec2")[account_id][region]
        if hasattr(backend, "get_security_group_from_id"):
            return backend.get_security_group_from_id(group_id)
        if hasattr(backend, "get_security_group_by_name_or_id"):
            return backend.get_security_group_by_name_or_id(group_id)
    except Exception:
        LOG.debug(
            "ec2 security-group lookup failed for %s", group_id, exc_info=True
        )
    return None


def _group_tags(group) -> dict[str, str]:
    from localemu.services.iam_enforcement.resource_tag_loader import (
        _normalize_tag_list,
    )

    try:
        return _normalize_tag_list(group.get_tags())
    except Exception:
        LOG.debug("ec2 security-group tag read failed", exc_info=True)
        return {}


def _apply_tag_specifications(conditions: dict, params: dict) -> None:
    from localemu.services.iam_enforcement.resource_tag_loader import (
        _normalize_tag_list,
    )

    specs = params.get("TagSpecifications") or params.get("TagSpecification") or []
    if isinstance(specs, dict):
        specs = [specs]
    if not isinstance(specs, list):
        return
    tag_keys = list(conditions.get("aws:TagKeys") or [])
    if not isinstance(tag_keys, list):
        tag_keys = [tag_keys] if tag_keys else []
    for spec in specs:
        if not isinstance(spec, dict):
            continue
        tags = spec.get("Tags") or spec.get("tags") or []
        for key, value in _normalize_tag_list(tags).items():
            conditions[f"aws:RequestTag/{key}"] = value
            if key not in tag_keys:
                tag_keys.append(key)
    if tag_keys:
        conditions["aws:TagKeys"] = tag_keys


def _install() -> None:
    from localemu.services.iam_enforcement import enforcer as enforcer_mod

    if getattr(enforcer_mod._build_conditions, "_awsbox_ec2_vpc_condition_keys", False):
        return

    orig = enforcer_mod._build_conditions

    def _build_conditions(context, caller):
        conditions = orig(context, caller)
        try:
            service = getattr(getattr(context, "service", None), "service_name", None)
            if service != "ec2":
                return conditions
            operation = getattr(getattr(context, "operation", None), "name", None)
            params = context.service_request or {}
            account_id = context.account_id or caller.account_id or "000000000000"
            region = context.region or "us-east-1"

            _apply_tag_specifications(conditions, params)

            if operation == "CreateSecurityGroup":
                vpc_id = params.get("VpcId") or params.get("vpcId")
                if isinstance(vpc_id, str) and vpc_id:
                    conditions["ec2:Vpc"] = _vpc_arn(region, account_id, vpc_id)

            for group_id in _sg_ids_from_params(params):
                group = _lookup_security_group(account_id, region, group_id)
                if group is None:
                    continue
                vpc_id = getattr(group, "vpc_id", None)
                if isinstance(vpc_id, str) and vpc_id:
                    conditions["ec2:Vpc"] = _vpc_arn(region, account_id, vpc_id)
                for key, value in _group_tags(group).items():
                    conditions[f"ec2:ResourceTag/{key}"] = value
                    aws_key = f"aws:ResourceTag/{key}"
                    if aws_key not in conditions:
                        conditions[aws_key] = value
                # First matching SG is enough for single-resource calls.
                break
        except Exception:
            LOG.debug("ec2 VPC/ResourceTag condition context failed", exc_info=True)
        return conditions

    _build_conditions._awsbox_ec2_vpc_condition_keys = True
    enforcer_mod._build_conditions = _build_conditions
    LOG.info("awsbox ec2:Vpc / ResourceTag / TagSpecifications condition keys applied")


_install()
