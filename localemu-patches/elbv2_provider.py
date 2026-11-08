"""Custom ELBv2 provider for LocalEmu.

Goes beyond Moto's state-only stub by running real HTTP listeners that
reverse-proxy to registered targets, plus active health checking
(TCP connect, or HTTP/HTTPS GET with path + matcher codes).

Operations intercepted:
  - CreateLoadBalancer        : normalize DNS name, track LB in router
  - CreateTargetGroup         : register TG in router
  - RegisterTargets           : add targets to router
  - DeregisterTargets         : remove targets from router
  - CreateListener            : start an actual HTTP listener (for HTTP ALBs)
  - DeleteListener            : stop the HTTP listener
  - DescribeLoadBalancers     : ensure DNS names match what we emit
  - DescribeTargetHealth      : return real probe-derived health
  - ModifyTargetGroup        : refresh health-check settings on the router

All other operations (rules, tags, SSL policies, attributes, NLB details,
etc.) fall through to Moto via `_proxy_moto`.
"""

from __future__ import annotations

import hashlib
import logging

from localemu.aws.api import RequestContext, ServiceRequest, ServiceResponse
from localemu.aws.skeleton import DispatchTable, Skeleton
from localemu.services.elbv2.listener_router import (
    TargetGroup,
    _parse_http_codes,
    get_router,
)
from localemu.services.moto import _proxy_moto, call_moto
from localemu.services.plugins import Service

LOG = logging.getLogger(__name__)


def _lb_dns_name(name: str, region: str) -> str:
    """AWS-style ALB DNS: {name}-{16-hex}.{region}.elb.amazonaws.com."""
    suffix = hashlib.md5(name.encode()).hexdigest()[:16]  # noqa: S324
    return f"{name}-{suffix}.{region}.elb.amazonaws.com"


def _subnet_vpc_id(subnet_id: str, account_id: str, region: str) -> str:
    if not subnet_id:
        return ""
    try:
        import moto.backends as moto_backends

        ec2 = moto_backends.get_backend("ec2")[account_id][region]
    except Exception:
        LOG.debug("elbv2: no ec2 backend for %s/%s", account_id, region, exc_info=True)
        return ""
    subnet = None
    subnets = getattr(ec2, "subnets", None)
    if isinstance(subnets, dict):
        subnet = subnets.get(subnet_id)
        if subnet is None:
            for entry in subnets.values():
                if isinstance(entry, dict) and subnet_id in entry:
                    subnet = entry[subnet_id]
                    break
    if subnet is None:
        getter = getattr(ec2, "get_subnet", None)
        if callable(getter):
            try:
                subnet = getter(subnet_id)
            except Exception:
                subnet = None
    if subnet is None:
        return ""
    vpc_id = getattr(subnet, "vpc_id", "") or ""
    if hasattr(vpc_id, "id"):
        vpc_id = vpc_id.id
    return str(vpc_id or "")


def _vpc_networks_from_lb(lb: dict, account_id: str, region: str) -> list[str]:
    nets: list[str] = []
    for az in lb.get("AvailabilityZones") or []:
        subnet_id = str(az.get("SubnetId") or "")
        vpc_id = _subnet_vpc_id(subnet_id, account_id, region)
        if not vpc_id:
            continue
        name = f"localemu-vpc-{vpc_id}"
        if name not in nets:
            nets.append(name)
    return nets



def _hc_fields_from_tg(tg: dict) -> dict:
    """Pull health-check settings from a Moto TargetGroup describe dict."""
    hc_port = tg.get("HealthCheckPort")
    try:
        hc_port_int = int(hc_port) if hc_port and str(hc_port).isdigit() else None
    except (ValueError, TypeError):
        hc_port_int = None
    matcher = tg.get("Matcher") or {}
    http_code = matcher.get("HttpCode") if isinstance(matcher, dict) else None
    proto = (tg.get("HealthCheckProtocol") or tg.get("Protocol") or "TCP")
    path = tg.get("HealthCheckPath") or "/"
    return {
        "health_check_port": hc_port_int,
        "health_check_protocol": str(proto).upper(),
        "health_check_path": str(path) if path else "/",
        "health_check_codes": _parse_http_codes(str(http_code or "200")),
    }


def _handle_create_load_balancer(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    region = context.region or "us-east-1"
    router = get_router()
    for lb in result.get("LoadBalancers", []) or []:
        name = lb.get("LoadBalancerName") or "lb"
        dns = _lb_dns_name(name, region)
        lb["DNSName"] = dns
        account_id = context.account_id or "000000000000"
        router.register_lb(
            arn=lb.get("LoadBalancerArn", ""),
            name=name,
            dns_name=dns,
            scheme=lb.get("Scheme", "internet-facing"),
            lb_type=lb.get("Type", "application"),
            vpc_networks=_vpc_networks_from_lb(lb, account_id, region),
        )
        LOG.info("ELBv2 LB created: %s (%s)", name, dns)
    return result


def _handle_describe_load_balancers(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    region = context.region or "us-east-1"
    for lb in result.get("LoadBalancers", []) or []:
        name = lb.get("LoadBalancerName")
        if name:
            lb["DNSName"] = _lb_dns_name(name, region)
    return result


def _handle_create_target_group(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    router = get_router()
    for tg in result.get("TargetGroups", []) or []:
        arn = tg.get("TargetGroupArn", "")
        if not arn:
            continue
        hc = _hc_fields_from_tg(tg)
        router.register_target_group(TargetGroup(
            arn=arn,
            name=tg.get("TargetGroupName", ""),
            protocol=tg.get("Protocol", "HTTP"),
            port=int(tg.get("Port") or 80),
            **hc,
        ))
    return result


def _handle_modify_target_group(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    router = get_router()
    for tg in result.get("TargetGroups", []) or []:
        arn = tg.get("TargetGroupArn", "")
        existing = router.target_groups.get(arn) if arn else None
        if not existing:
            continue
        hc = _hc_fields_from_tg(tg)
        existing.health_check_port = hc["health_check_port"]
        existing.health_check_protocol = hc["health_check_protocol"]
        existing.health_check_path = hc["health_check_path"]
        existing.health_check_codes = hc["health_check_codes"]
    return result


def _handle_register_targets(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    tg_arn = request.get("TargetGroupArn")
    targets = request.get("Targets") or []
    if tg_arn and targets:
        get_router().add_targets(tg_arn, targets)
    return result


def _handle_deregister_targets(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    tg_arn = request.get("TargetGroupArn")
    targets = request.get("Targets") or []
    if tg_arn and targets:
        get_router().remove_targets(tg_arn, targets)
    return result


def _listener_certificate_arn(listener: dict, request: ServiceRequest) -> str:
    """First CertificateArn from the moto listener or the create request."""
    for source in (listener.get("Certificates"), request.get("Certificates")):
        for entry in source or []:
            arn = entry.get("CertificateArn") or ""
            if arn:
                return str(arn)
    return ""


def _forward_tg_arn(actions: list | None) -> str:
    for action in actions or []:
        if not isinstance(action, dict):
            continue
        if action.get("Type") != "forward":
            continue
        tg = action.get("TargetGroupArn") or ""
        if tg:
            return str(tg)
        fw = action.get("ForwardConfig") or {}
        tgs = fw.get("TargetGroups") or []
        if tgs and isinstance(tgs[0], dict):
            return str(tgs[0].get("TargetGroupArn") or "")
    return ""


def _handle_create_listener(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    router = get_router()
    for listener in result.get("Listeners", []) or []:
        protocol = listener.get("Protocol", "HTTP")
        lb_arn = listener.get("LoadBalancerArn", "")
        listener_arn = listener.get("ListenerArn", "")
        if protocol.upper() not in ("HTTP", "HTTPS", "TCP", "TLS"):
            LOG.info("ELBv2 listener %s protocol %s is not forwarded", listener_arn, protocol)
            continue
        requested_port = int(listener.get("Port") or 80)

        target_group_arn = _forward_tg_arn(listener.get("DefaultActions"))
        if not target_group_arn:
            LOG.debug("Listener %s has no forward action; skipping HTTP proxy", listener_arn)
            continue

        meta = router.load_balancers.get(lb_arn) or {}
        actual_port = router.start_listener(
            lb_arn=lb_arn,
            listener_arn=listener_arn,
            protocol=protocol,
            requested_port=requested_port,
            target_group_arn=target_group_arn,
            scheme=str(meta.get("scheme") or "internet-facing"),
            vpc_networks=list(meta.get("vpc_networks") or []),
            certificate_arn=_listener_certificate_arn(listener, request) or None,
        )
        # Surface the real bound port via a non-AWS field so clients that care
        # (tests, dashboard) can discover it; advertised Port stays as requested.
        if actual_port:
            listener["LocalEmuBoundPort"] = actual_port
    return result


def _handle_delete_load_balancer(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    lb_arn = request.get("LoadBalancerArn") or ""
    router = get_router()
    to_stop = router.listener_arns_for(lb_arn) if lb_arn else []
    result = call_moto(context)
    for listener_arn in to_stop:
        router.stop_listener(listener_arn)
    if lb_arn:
        router.forget_lb(lb_arn)
    return result


def _handle_delete_listener(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    listener_arn = request.get("ListenerArn") or ""
    result = call_moto(context)
    if listener_arn:
        get_router().stop_listener(listener_arn)
    return result


def _handle_modify_listener(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """Keep the dataplane default TG in sync when DefaultActions change.

    CodeDeploy blue/green (and any ModifyListener swap) used to rely on the
    ECS loopback forwarder re-reading moto each accept. With #247 that
    stand-in is gone, so the L4/HTTP listener must retarget here.
    """
    result = call_moto(context)
    listener_arn = str(request.get("ListenerArn") or "")
    tg_arn = _forward_tg_arn(request.get("DefaultActions"))
    if not tg_arn:
        for listener in result.get("Listeners", []) or []:
            if str(listener.get("ListenerArn") or "") == listener_arn:
                tg_arn = _forward_tg_arn(listener.get("DefaultActions"))
                break
    if listener_arn and tg_arn:
        get_router().set_listener_target_group(listener_arn, tg_arn)
    return result


def _record_rule(rule: dict) -> None:
    """Mirror a moto-returned Rule into the proxy router so request
    routing actually honours its conditions/actions on the next hit."""
    rule_arn = rule.get("RuleArn") or ""
    if not rule_arn:
        return
    # moto returns ListenerArn on the rule object since elbv2 v3; older
    # versions omit it and the caller had to know it. Fall back to a scan
    # over our own listener map keyed by load-balancer ownership.
    listener_arn = rule.get("ListenerArn", "")
    if not listener_arn:
        # Worst case: pick the listener whose default TG matches one of
        # the rule's forward actions; if that fails too, drop silently.
        router_inst = get_router()
        for la, listener in router_inst.listeners.items():
            if any(
                (a.get("TargetGroupArn") or "") == listener.target_group_arn
                for a in (rule.get("Actions") or [])
            ):
                listener_arn = la
                break
    if not listener_arn:
        LOG.debug("CreateRule: no listener arn resolvable for %s; not recording", rule_arn)
        return
    get_router().register_rule(
        rule_arn=rule_arn,
        listener_arn=listener_arn,
        priority=str(rule.get("Priority") or "default"),
        conditions=rule.get("Conditions") or [],
        actions=rule.get("Actions") or [],
    )


def _handle_create_rule(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    # moto returns the rule with its ARN populated.
    listener_arn = request.get("ListenerArn") or ""
    for rule in result.get("Rules", []) or []:
        if listener_arn and not rule.get("ListenerArn"):
            rule["ListenerArn"] = listener_arn
        _record_rule(rule)
    return result


def _handle_modify_rule(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    for rule in result.get("Rules", []) or []:
        _record_rule(rule)
    return result


def _handle_delete_rule(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    rule_arn = request.get("RuleArn") or ""
    result = call_moto(context)
    if rule_arn:
        get_router().remove_rule(rule_arn)
    return result


def _handle_set_rule_priorities(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    mapping = {
        item.get("RuleArn"): str(item.get("Priority"))
        for item in (request.get("RulePriorities") or [])
        if item.get("RuleArn") is not None
    }
    if mapping:
        get_router().set_rule_priorities(mapping)
    return result


def _handle_describe_target_health(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    tg_arn = request.get("TargetGroupArn")
    if not tg_arn:
        return call_moto(context)

    router = get_router()
    if tg_arn not in router.target_groups:
        # Unknown to our router -> let Moto answer (state-only).
        return call_moto(context)

    descriptions = router.describe_target_health(tg_arn)

    # Allow filtering by requested Targets list, like the real API does.
    wanted = request.get("Targets") or []
    if wanted:
        wanted_keys = {(t.get("Id"), int(t.get("Port") or 0)) for t in wanted}
        descriptions = [
            d for d in descriptions
            if (d["Target"]["Id"], int(d["Target"]["Port"])) in wanted_keys
               or (d["Target"]["Id"], 0) in wanted_keys
        ]

    return {"TargetHealthDescriptions": descriptions}


_INTERCEPTED_OPS = {
    "CreateLoadBalancer": _handle_create_load_balancer,
    "DeleteLoadBalancer": _handle_delete_load_balancer,
    "DescribeLoadBalancers": _handle_describe_load_balancers,
    "CreateTargetGroup": _handle_create_target_group,
    "ModifyTargetGroup": _handle_modify_target_group,
    "RegisterTargets": _handle_register_targets,
    "DeregisterTargets": _handle_deregister_targets,
    "CreateListener": _handle_create_listener,
    "DeleteListener": _handle_delete_listener,
    "ModifyListener": _handle_modify_listener,
    "DescribeTargetHealth": _handle_describe_target_health,
    "CreateRule": _handle_create_rule,
    "ModifyRule": _handle_modify_rule,
    "DeleteRule": _handle_delete_rule,
    "SetRulePriorities": _handle_set_rule_priorities,
}


def Elbv2Dispatcher(service_model) -> DispatchTable:
    table = {}
    for op in service_model.operation_names:
        table[op] = _INTERCEPTED_OPS.get(op, _proxy_moto)
    return table


def create_elbv2_service() -> Service:
    from localemu.aws.spec import load_service

    service_model = load_service("elbv2")
    dispatch_table = Elbv2Dispatcher(service_model)
    skeleton = Skeleton(service_model, dispatch_table)
    return Service(name="elbv2", skeleton=skeleton)
