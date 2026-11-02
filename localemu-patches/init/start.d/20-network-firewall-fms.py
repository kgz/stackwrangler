"""Network Firewall policy/rule-group + Firewall Manager stubs (#109).

moto's networkfirewall covers Create/Describe/List firewall + logging but not
policy/rule-group APIs. Those are stubbed via stub_providers (moto fallthrough
for the rest). FMS has no moto backend — pure stub_providers Put/Get/List/Delete
policy store. Control plane only; no packet filtering or org enforcement.
"""

from __future__ import annotations

import logging
import threading
import uuid

LOG = logging.getLogger("localemu.awsbox.network_firewall_fms")

_LOCK = threading.RLock()
_RULE_GROUPS: dict[tuple[str, str], dict[str, dict]] = {}
_FW_POLICIES: dict[tuple[str, str], dict[str, dict]] = {}
_FMS_POLICIES: dict[tuple[str, str], dict[str, dict]] = {}


def _new_id() -> str:
    return str(uuid.uuid4())


def _error(code: str, message: str, status: int = 400):
    from localemu.aws.api import CommonServiceException

    raise CommonServiceException(
        code=code, message=message, status_code=status, sender_fault=True
    )


def _bucket(store: dict, account: str, region: str) -> dict[str, dict]:
    with _LOCK:
        return store.setdefault((account, region), {})


# ---- Network Firewall rule group / firewall policy --------------------------


def _create_rule_group(context, request):
    name = request.get("RuleGroupName") or ""
    type_ = request.get("Type") or ""
    if not name or not type_:
        _error("InvalidRequestException", "RuleGroupName and Type are required")
    bucket = _bucket(_RULE_GROUPS, context.account_id, context.region)
    if any(e["RuleGroupResponse"]["RuleGroupName"] == name for e in bucket.values()):
        _error("InvalidRequestException", f"Rule group {name} already exists")
    rg_id = _new_id()
    arn = (
        f"arn:aws:network-firewall:{context.region}:{context.account_id}"
        f":rulegroup/{name}"
    )
    body = dict(request.get("RuleGroup") or {})
    rules = request.get("Rules")
    if rules and "RulesSource" not in body:
        body = {**body, "RulesSource": {"RulesString": rules}}
    entry = {
        "RuleGroup": body,
        "RuleGroupResponse": {
            "RuleGroupArn": arn,
            "RuleGroupName": name,
            "RuleGroupId": rg_id,
            "Description": request.get("Description") or "",
            "Type": type_,
            "Capacity": int(request.get("Capacity") or 0),
            "RuleGroupStatus": "ACTIVE",
            "Tags": request.get("Tags") or [],
            "ConsumedCapacity": int(request.get("Capacity") or 0),
            "NumberOfAssociations": 0,
        },
        "UpdateToken": _new_id(),
    }
    with _LOCK:
        bucket[arn] = entry
    return {
        "UpdateToken": entry["UpdateToken"],
        "RuleGroupResponse": entry["RuleGroupResponse"],
    }


def _find_rule_group(bucket: dict[str, dict], request) -> dict:
    arn = request.get("RuleGroupArn")
    name = request.get("RuleGroupName")
    type_ = request.get("Type")
    if arn and arn in bucket:
        return bucket[arn]
    for entry in bucket.values():
        resp = entry["RuleGroupResponse"]
        if resp["RuleGroupName"] == name and (type_ is None or resp.get("Type") == type_):
            return entry
    _error(
        "ResourceNotFoundException",
        f"Rule group {arn or name} not found",
        404,
    )


def _describe_rule_group(context, request):
    bucket = _bucket(_RULE_GROUPS, context.account_id, context.region)
    entry = _find_rule_group(bucket, request)
    return {
        "UpdateToken": entry["UpdateToken"],
        "RuleGroup": entry["RuleGroup"],
        "RuleGroupResponse": entry["RuleGroupResponse"],
    }


def _list_rule_groups(context, request):
    del request
    bucket = _bucket(_RULE_GROUPS, context.account_id, context.region)
    return {
        "RuleGroups": [
            {
                "Name": e["RuleGroupResponse"]["RuleGroupName"],
                "Arn": e["RuleGroupResponse"]["RuleGroupArn"],
            }
            for e in bucket.values()
        ]
    }


def _delete_rule_group(context, request):
    bucket = _bucket(_RULE_GROUPS, context.account_id, context.region)
    entry = _find_rule_group(bucket, request)
    arn = entry["RuleGroupResponse"]["RuleGroupArn"]
    with _LOCK:
        del bucket[arn]
    return {"RuleGroupResponse": entry["RuleGroupResponse"]}


def _create_firewall_policy(context, request):
    name = request.get("FirewallPolicyName") or ""
    if not name:
        _error("InvalidRequestException", "FirewallPolicyName is required")
    bucket = _bucket(_FW_POLICIES, context.account_id, context.region)
    if any(
        e["FirewallPolicyResponse"]["FirewallPolicyName"] == name for e in bucket.values()
    ):
        _error("InvalidRequestException", f"Firewall policy {name} already exists")
    policy_id = _new_id()
    arn = (
        f"arn:aws:network-firewall:{context.region}:{context.account_id}"
        f":firewall-policy/{name}"
    )
    entry = {
        "FirewallPolicy": dict(request.get("FirewallPolicy") or {}),
        "FirewallPolicyResponse": {
            "FirewallPolicyName": name,
            "FirewallPolicyArn": arn,
            "FirewallPolicyId": policy_id,
            "Description": request.get("Description") or "",
            "FirewallPolicyStatus": "ACTIVE",
            "Tags": request.get("Tags") or [],
            "NumberOfAssociations": 0,
        },
        "UpdateToken": _new_id(),
    }
    with _LOCK:
        bucket[arn] = entry
    return {
        "UpdateToken": entry["UpdateToken"],
        "FirewallPolicyResponse": entry["FirewallPolicyResponse"],
    }


def _find_firewall_policy(bucket: dict[str, dict], request) -> dict:
    arn = request.get("FirewallPolicyArn")
    name = request.get("FirewallPolicyName")
    if arn and arn in bucket:
        return bucket[arn]
    for entry in bucket.values():
        if entry["FirewallPolicyResponse"]["FirewallPolicyName"] == name:
            return entry
    _error(
        "ResourceNotFoundException",
        f"Firewall policy {arn or name} not found",
        404,
    )


def _describe_firewall_policy(context, request):
    bucket = _bucket(_FW_POLICIES, context.account_id, context.region)
    entry = _find_firewall_policy(bucket, request)
    return {
        "UpdateToken": entry["UpdateToken"],
        "FirewallPolicyResponse": entry["FirewallPolicyResponse"],
        "FirewallPolicy": entry["FirewallPolicy"],
    }


def _list_firewall_policies(context, request):
    del request
    bucket = _bucket(_FW_POLICIES, context.account_id, context.region)
    return {
        "FirewallPolicies": [
            {
                "Name": e["FirewallPolicyResponse"]["FirewallPolicyName"],
                "Arn": e["FirewallPolicyResponse"]["FirewallPolicyArn"],
            }
            for e in bucket.values()
        ]
    }


def _delete_firewall_policy(context, request):
    bucket = _bucket(_FW_POLICIES, context.account_id, context.region)
    entry = _find_firewall_policy(bucket, request)
    arn = entry["FirewallPolicyResponse"]["FirewallPolicyArn"]
    with _LOCK:
        del bucket[arn]
    return {"FirewallPolicyResponse": entry["FirewallPolicyResponse"]}


def _install_networkfirewall_ops() -> None:
    from localemu.services import stub_providers

    ops = stub_providers._OPS.setdefault("network-firewall", {})
    ops.update(
        {
            "CreateRuleGroup": _create_rule_group,
            "DescribeRuleGroup": _describe_rule_group,
            "ListRuleGroups": _list_rule_groups,
            "DeleteRuleGroup": _delete_rule_group,
            "CreateFirewallPolicy": _create_firewall_policy,
            "DescribeFirewallPolicy": _describe_firewall_policy,
            "ListFirewallPolicies": _list_firewall_policies,
            "DeleteFirewallPolicy": _delete_firewall_policy,
        }
    )
    stub_providers._HAS_MOTO_BACKEND.add("network-firewall")
    LOG.info("awsbox network-firewall policy/rule-group stub_providers ops registered")


# ---- FMS --------------------------------------------------------------------


def _fms_put_policy(context, request):
    policy_in = dict(request.get("Policy") or {})
    name = policy_in.get("PolicyName") or ""
    if not name:
        _error("InvalidInputException", "Policy.PolicyName is required")
    bucket = _bucket(_FMS_POLICIES, context.account_id, context.region)
    existing_id = policy_in.get("PolicyId")
    policy_id = existing_id if existing_id and existing_id in bucket else _new_id()
    token = _new_id()
    policy = {
        **policy_in,
        "PolicyId": policy_id,
        "PolicyName": name,
        "PolicyUpdateToken": token,
        "PolicyStatus": policy_in.get("PolicyStatus") or "ACTIVE",
    }
    arn = f"arn:aws:fms:{context.region}:{context.account_id}:policy/{policy_id}"
    with _LOCK:
        bucket[policy_id] = {"Policy": policy, "PolicyArn": arn}
    return {"Policy": policy, "PolicyArn": arn}


def _fms_get_policy(context, request):
    policy_id = request.get("PolicyId") or ""
    bucket = _bucket(_FMS_POLICIES, context.account_id, context.region)
    found = bucket.get(policy_id)
    if found is None:
        _error("ResourceNotFoundException", f"Policy {policy_id} not found", 404)
    return {"Policy": dict(found["Policy"]), "PolicyArn": found["PolicyArn"]}


def _fms_list_policies(context, request):
    del request
    bucket = _bucket(_FMS_POLICIES, context.account_id, context.region)
    summaries = []
    for item in bucket.values():
        p = item["Policy"]
        summaries.append(
            {
                "PolicyArn": item["PolicyArn"],
                "PolicyId": p["PolicyId"],
                "PolicyName": p.get("PolicyName"),
                "ResourceType": p.get("ResourceType"),
                "RemediationEnabled": p.get("RemediationEnabled", False),
                "SecurityServiceType": (p.get("SecurityServicePolicyData") or {}).get(
                    "Type"
                ),
            }
        )
    return {"PolicyList": summaries}


def _fms_delete_policy(context, request):
    policy_id = request.get("PolicyId") or ""
    bucket = _bucket(_FMS_POLICIES, context.account_id, context.region)
    with _LOCK:
        if policy_id not in bucket:
            _error("ResourceNotFoundException", f"Policy {policy_id} not found", 404)
        del bucket[policy_id]
    return {}


def _fms_list_apps_lists(context, request):
    del context, request
    return {"AppsLists": []}


def _install_fms_ops() -> None:
    from localemu.services import stub_providers

    ops = stub_providers._OPS.setdefault("fms", {})
    ops.update(
        {
            "PutPolicy": _fms_put_policy,
            "GetPolicy": _fms_get_policy,
            "ListPolicies": _fms_list_policies,
            "DeletePolicy": _fms_delete_policy,
            "ListAppsLists": _fms_list_apps_lists,
        }
    )
    LOG.info("awsbox fms stub_providers ops registered")


# ---- Register LocalEmu service plugins --------------------------------------


def _register_plugin(api: str, create_service) -> None:
    import threading

    from plux import PluginSpec
    from plux.runtime.manager import PluginContainer

    from localemu.services.plugins import (
        PLUGIN_NAMESPACE,
        SERVICE_PLUGINS,
        ServicePluginAdapter,
    )
    from localemu.utils.bootstrap import get_enabled_apis, get_preloaded_services

    plugin_name = f"{api}:default"
    pm = SERVICE_PLUGINS.plugin_manager
    if plugin_name in pm._plugins:
        LOG.info("plugin %s already present", plugin_name)
        return

    def factory():
        return ServicePluginAdapter(api=api, create_service=create_service)

    spec = PluginSpec(PLUGIN_NAMESPACE, plugin_name, factory=factory)
    container = PluginContainer()
    container.lock = threading.RLock()
    container.name = plugin_name
    container.plugin_spec = spec
    pm._plugins[plugin_name] = container
    SERVICE_PLUGINS._api_provider_specs = None
    get_enabled_apis.cache_clear()
    get_preloaded_services.cache_clear()
    LOG.info("registered LocalEmu plugin %s", plugin_name)


def _create_networkfirewall_service():
    from localemu.services.stub_providers import create_stub_service

    return create_stub_service("network-firewall")


def _create_fms_service():
    from localemu.services.stub_providers import create_stub_service

    return create_stub_service("fms")


def _install() -> None:
    _install_networkfirewall_ops()
    _install_fms_ops()
    _register_plugin("network-firewall", _create_networkfirewall_service)
    _register_plugin("fms", _create_fms_service)
    try:
        from localemu.services.plugins import SERVICE_PLUGINS

        for api in ("network-firewall", "fms"):
            try:
                SERVICE_PLUGINS.require(api)
            except Exception as exc:
                LOG.warning("eager require %s failed (lazy load ok): %s", api, exc)
    except Exception as exc:
        LOG.warning("service require skipped: %s", exc)


_install()
