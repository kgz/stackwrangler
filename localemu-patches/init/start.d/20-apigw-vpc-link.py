"""Route REST VPC_LINK HTTP(S)_PROXY integrations through the ELBv2 data plane.

``put-integration --connection-type VPC_LINK`` is accepted, but invoke used to
``requests`` the integration URI from inside LocalEmu. Internal NLB DNS names
do not resolve there, so the call returns 500.

This hook:
1. Rewrites NLB ``*.elb.amazonaws.com`` hosts to the listener bind address from
   the ELBv2 router (so VPC_LINK works even if /etc/hosts is stale).
2. Leaves non-NLB URIs unchanged (INTERNET integrations keep their old path).
"""

from __future__ import annotations

import logging
from urllib.parse import urlparse, urlunparse

LOG = logging.getLogger("localemu.awsbox.apigw_vpc_link")


def _nlb_rewrite(uri: str) -> str:
    if not uri:
        return uri
    try:
        parsed = urlparse(uri)
    except Exception:
        return uri
    host = (parsed.hostname or "").lower()
    if not host.endswith(".elb.amazonaws.com"):
        return uri
    try:
        from localemu.services.elbv2.listener_router import get_router
    except Exception:
        return uri
    router = get_router()
    lb = None
    with router._lock:
        for entry in router.load_balancers.values():
            if str(entry.get("dns_name") or "").lower() == host:
                lb = entry
                break
    if lb is None:
        return uri
    lb_arn = str(lb.get("arn") or "")
    port = parsed.port
    if port is None:
        port = 443 if (parsed.scheme or "http").lower() == "https" else 80
    # Prefer an L4 (NLB) listener on the requested port; fall back to HTTP.
    bind_host = ""
    with router._lock:
        for l4 in router.l4_listeners.values():
            if l4.lb_arn == lb_arn and int(l4.port) == int(port):
                if l4.dest_ips:
                    bind_host = l4.dest_ips[0]
                break
        if not bind_host:
            for listener in router.listeners.values():
                if listener.lb_arn == lb_arn and int(listener.port) == int(port):
                    nets = list(lb.get("vpc_networks") or [])
                    scheme = str(lb.get("scheme") or "internet-facing")
                    from localemu.services.elbv2.listener_router import _bind_host

                    bind_host = _bind_host(scheme, nets)
                    if bind_host == "0.0.0.0":
                        bind_host = "127.0.0.1"
                    break
    if not bind_host:
        # Last resort: whatever _publish_dns put in /etc/hosts (or VPC join IP).
        nets = list(lb.get("vpc_networks") or [])
        from localemu.services.elbv2.listener_router import _join_network, _edge_ip

        for net in nets:
            ip = _join_network(net)
            if ip:
                bind_host = ip
                break
        if not bind_host:
            bind_host = _edge_ip() or "127.0.0.1"
    netloc = f"{bind_host}:{port}"
    rewritten = urlunparse(
        (parsed.scheme, netloc, parsed.path, parsed.params, parsed.query, parsed.fragment)
    )
    if rewritten != uri:
        LOG.debug("VPC_LINK/NLB rewrite %s -> %s", uri, rewritten)
    return rewritten


def _patch_http_integrations() -> None:
    from localemu.services.apigateway.next_gen.execute_api.integrations import http as http_mod

    for cls_name in ("RestApiHttpIntegration", "RestApiHttpProxyIntegration"):
        cls = getattr(http_mod, cls_name, None)
        if cls is None or getattr(cls, "_awsbox_vpc_link", False):
            continue
        original = cls.invoke

        def invoke(self, context, _original=original):
            req = context.integration_request
            if req is not None and req.get("uri"):
                req["uri"] = _nlb_rewrite(req["uri"])
            return _original(self, context)

        cls.invoke = invoke
        cls._awsbox_vpc_link = True
    LOG.info("awsbox REST VPC_LINK / NLB URI rewrite applied")


_patch_http_integrations()
