"""Custom ELBv2 provider for LocalEmu.

Goes beyond Moto's state-only stub by running real HTTP listeners that
reverse-proxy to registered targets, plus active TCP health checking.

Operations intercepted:
  - CreateLoadBalancer        : normalize DNS name, track LB in router
  - CreateTargetGroup         : register TG in router
  - RegisterTargets           : add targets to router
  - DeregisterTargets         : remove targets from router
  - CreateListener            : start an actual HTTP listener (for HTTP ALBs)
  - ModifyListener            : reload ACM TLS material when certificates change
  - AddListenerCertificates   : reload ACM TLS material after certs are added
  - DeleteListener            : stop the HTTP listener
  - DescribeLoadBalancers     : ensure DNS names match what we emit
  - DescribeTargetHealth      : return real TCP-probe-derived health

All other operations (rules, tags, SSL policies, attributes, NLB details,
etc.) fall through to Moto via `_proxy_moto`.
"""

from __future__ import annotations

import hashlib
import logging

from localemu.aws.api import RequestContext, ServiceRequest, ServiceResponse
from localemu.aws.skeleton import DispatchTable, Skeleton
from localemu.services.elbv2.listener_router import TargetGroup, get_router
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
        hc_port = tg.get("HealthCheckPort")
        try:
            hc_port_int = int(hc_port) if hc_port and str(hc_port).isdigit() else None
        except (ValueError, TypeError):
            hc_port_int = None
        router.register_target_group(TargetGroup(
            arn=arn,
            name=tg.get("TargetGroupName", ""),
            protocol=tg.get("Protocol", "HTTP"),
            port=int(tg.get("Port") or 80),
            health_check_port=hc_port_int,
        ))
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


def _certificate_arn_from_entry(entry) -> str:
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        return str(entry.get("CertificateArn") or "")
    return ""


def _first_certificate_arn(*sources) -> str:
    for source in sources:
        for entry in source or []:
            arn = _certificate_arn_from_entry(entry)
            if arn:
                return arn
    return ""


def _listener_certificate_arn(listener: dict, request: ServiceRequest) -> str:
    """First CertificateArn from the moto listener or the create request."""
    return _first_certificate_arn(
        listener.get("Certificates"),
        request.get("Certificates"),
    )


def _sync_listener_certificates(
    context: RequestContext, listener_arn: str, certificates: list,
) -> str:
    """Write certificate ARNs onto the moto listener and return the default.

    Moto's ModifyListener only rewrites certificates for HTTPS. TLS NLB
    listeners need the same update so DescribeListenerCertificates and the
    live reload agree (#594).
    """
    arns = [
        arn for arn in (_certificate_arn_from_entry(entry) for entry in certificates)
        if arn
    ]
    if not listener_arn or not arns:
        return ""
    try:
        import moto.backends as moto_backends

        account_id = context.account_id or "000000000000"
        region = context.region or "us-east-1"
        backend = moto_backends.get_backend("elbv2")[account_id][region]
        listeners = backend.describe_listeners(
            load_balancer_arn=None, listener_arns=[listener_arn],
        )
        if not listeners:
            return arns[0]
        listener = listeners[0]
        if (listener.protocol or "").upper() in {"HTTPS", "TLS"}:
            listener.certificate = arns[0]
            listener.certificates = list(arns)
    except Exception:
        LOG.debug(
            "elbv2: could not sync certificates for %s", listener_arn, exc_info=True,
        )
    return arns[0]


def _default_certificate_arn(
    context: RequestContext, listener_arn: str, *sources,
) -> str:
    """Prefer request/result ARNs; else the moto listener's default cert."""
    arn = _first_certificate_arn(*sources)
    if arn or not listener_arn:
        return arn
    try:
        import moto.backends as moto_backends

        account_id = context.account_id or "000000000000"
        region = context.region or "us-east-1"
        backend = moto_backends.get_backend("elbv2")[account_id][region]
        listeners = backend.describe_listeners(
            load_balancer_arn=None, listener_arns=[listener_arn],
        )
        if not listeners:
            return ""
        listener = listeners[0]
        if listener.certificate:
            return str(listener.certificate)
        if listener.certificates:
            return str(listener.certificates[0])
    except Exception:
        LOG.debug(
            "elbv2: could not read default certificate for %s",
            listener_arn, exc_info=True,
        )
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

        # Pick the default target group from DefaultActions.
        target_group_arn = ""
        for action in listener.get("DefaultActions", []) or []:
            if action.get("Type") == "forward":
                target_group_arn = action.get("TargetGroupArn", "")
                if not target_group_arn:
                    fw = action.get("ForwardConfig") or {}
                    tgs = fw.get("TargetGroups") or []
                    if tgs:
                        target_group_arn = tgs[0].get("TargetGroupArn", "")
                if target_group_arn:
                    break

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


def _handle_modify_listener(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    listener_arn = str(request.get("ListenerArn") or "")
    certificates = request.get("Certificates") or []
    if listener_arn and certificates:
        cert_arn = _sync_listener_certificates(context, listener_arn, certificates)
        for listener in result.get("Listeners", []) or []:
            if listener.get("ListenerArn") == listener_arn:
                listener["Certificates"] = [
                    {"CertificateArn": _certificate_arn_from_entry(entry)}
                    for entry in certificates
                    if _certificate_arn_from_entry(entry)
                ]
        if cert_arn:
            get_router().reload_listener_certificate(listener_arn, cert_arn)
    return result


def _handle_add_listener_certificates(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    result = call_moto(context)
    listener_arn = str(request.get("ListenerArn") or "")
    certificates = request.get("Certificates") or []
    if listener_arn and certificates:
        # Default cert is certificates[0] after the add (AWS / moto).
        cert_arn = _default_certificate_arn(
            context,
            listener_arn,
            result.get("Certificates"),
            certificates,
        )
        if cert_arn:
            get_router().reload_listener_certificate(listener_arn, cert_arn)
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
    "RegisterTargets": _handle_register_targets,
    "DeregisterTargets": _handle_deregister_targets,
    "CreateListener": _handle_create_listener,
    "ModifyListener": _handle_modify_listener,
    "AddListenerCertificates": _handle_add_listener_certificates,
    "DeleteListener": _handle_delete_listener,
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
