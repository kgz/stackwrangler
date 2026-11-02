"""Apply subnet route tables to workload containers.

EC2's primary Docker network is the non-internal pubport bridge, so a
private subnet still has a default route unless we remove it. Peering
and NAT are attached for the whole VPC; this module keeps them in step
with the subnet route table.

Gateway endpoint routes (S3 / DynamoDB prefix lists → ``vpce-*``) expand
into the allow list and DNAT those CIDRs to the endpoint proxy so a
private workload reaches the service only when the route exists (#230).

Packets are filtered in mangle OUTPUT, which runs before nat OUTPUT.
That sees the original destination (the peer VPC IP) rather than the
peering-bridge address the DNAT rule rewrites it to.
"""

from __future__ import annotations

import ipaddress
import logging
import os
import threading

LOG = logging.getLogger("localemu.awsbox.vpc_routing")

_PUBPORT = "localemu-pubport-br"
_MARKER = "/var/lib/localemu/awsbox-igw-routes.txt"
_CHAIN = "AWSBOX-RT"
_VPCE_CHAIN = "AWSBOX-VPCE"
# container → (subnet_id, account_id, region) for non-EC2 workloads
_workloads: dict[str, tuple[str, str, str]] = {}
_workloads_lock = threading.Lock()
# Prefer alpine netns sidecar when the workload image has no iptables (Lambda).
_netns = threading.local()


def sync_vpc(vpc_id: str, account_id: str | None = None, region: str | None = None) -> None:
    account_id, region, backend = _find_backend(vpc_id, account_id, region)
    if backend is None or not account_id or not region:
        return
    from localemu.services.ec2.docker.instance_routes import (
        _all_instances,
        _get_subnet,
        container_name_for_instance,
    )

    for inst in _all_instances(backend):
        state = getattr(inst, "_state", None) or getattr(inst, "state", None)
        state_name = getattr(state, "name", None) if state is not None else None
        if state_name and state_name not in ("running", "pending"):
            continue
        subnet_id = getattr(inst, "subnet_id", None)
        instance_id = getattr(inst, "id", None)
        if not subnet_id or not instance_id:
            continue
        inst_vpc = getattr(inst, "vpc_id", None)
        if not inst_vpc:
            subnet = _get_subnet(backend, subnet_id)
            inst_vpc = getattr(subnet, "vpc_id", None) if subnet is not None else None
        if inst_vpc != vpc_id:
            continue
        container = container_name_for_instance(instance_id)
        if not _running(container):
            continue
        sync_container(container, subnet_id, account_id, region, vpc_id)


def sync_route_table(route_table_id: str, account_id: str, region: str) -> None:
    from localemu.services.ec2.docker.instance_routes import (
        get_subnets_for_route_table,
    )

    for subnet_id in get_subnets_for_route_table(route_table_id, account_id, region):
        sync_subnet(subnet_id, account_id, region)


def sync_subnet(subnet_id: str, account_id: str, region: str) -> None:
    from localemu.services.ec2.docker.instance_routes import (
        _ec2_backend,
        _get_subnet,
        get_containers_in_subnet,
    )

    backend = _ec2_backend(account_id, region)
    if backend is None:
        return
    subnet = _get_subnet(backend, subnet_id)
    vpc_id = getattr(subnet, "vpc_id", None) if subnet is not None else None
    if not vpc_id:
        return
    for _instance_id, container in get_containers_in_subnet(subnet_id, account_id, region):
        if not _running(container):
            continue
        sync_container(container, subnet_id, account_id, region, vpc_id)
    with _workloads_lock:
        extras = [
            (name, sub, acct, reg)
            for name, (sub, acct, reg) in _workloads.items()
            if sub == subnet_id
        ]
    for name, sub, acct, reg in extras:
        if not _running(name):
            continue
        sync_container(name, sub, acct, reg, vpc_id)


def register_workload(
    container: str, subnet_id: str, account_id: str, region: str
) -> None:
    if not container or not subnet_id or not account_id or not region:
        return
    with _workloads_lock:
        _workloads[container] = (subnet_id, account_id, region)


def unregister_workload(container: str) -> None:
    with _workloads_lock:
        _workloads.pop(container, None)


def sync_workload(container: str, subnet_id: str, account_id: str, region: str) -> None:
    """ECS / Lambda (and any non-EC2 workload) on a subnet."""
    from localemu.services.ec2.docker.instance_routes import _ec2_backend, _get_subnet

    if not container or not subnet_id or not account_id or not region:
        return
    register_workload(container, subnet_id, account_id, region)
    ensure_restart_watcher()
    backend = _ec2_backend(account_id, region)
    if backend is None:
        return
    subnet = _get_subnet(backend, subnet_id)
    vpc_id = getattr(subnet, "vpc_id", None) if subnet is not None else None
    if not vpc_id:
        return
    sync_container(container, subnet_id, account_id, region, vpc_id)


def replay_workload(container: str) -> None:
    """Re-apply routes after ``docker start`` / container restart (#230)."""
    with _workloads_lock:
        info = _workloads.get(container)
    if not info:
        return
    subnet_id, account_id, region = info
    sync_workload(container, subnet_id, account_id, region)


_restart_watcher_started = False
_restart_watcher_lock = threading.Lock()


def ensure_restart_watcher() -> None:
    """CLI ``docker start`` bypasses LocalEmu's client hook — watch events."""
    global _restart_watcher_started
    with _restart_watcher_lock:
        if _restart_watcher_started:
            return
        _restart_watcher_started = True

    def _loop() -> None:
        try:
            import docker

            client = docker.from_env()
        except Exception:
            LOG.debug("vpc restart watcher: docker client unavailable", exc_info=True)
            return
        try:
            for event in client.events(
                decode=True, filters={"type": "container", "event": "start"}
            ):
                attrs = event.get("Actor", {}).get("Attributes", {}) or {}
                name = str(attrs.get("name") or "").lstrip("/")
                if not name:
                    continue
                with _workloads_lock:
                    known = name in _workloads
                if not known:
                    continue
                try:
                    # Netns needs a beat after start before iptables applies.
                    import time

                    time.sleep(0.3)
                    replay_workload(name)
                    LOG.info("vpc routes replayed after docker start %s", name)
                except Exception:
                    LOG.debug(
                        "vpc route replay on start event failed for %s",
                        name,
                        exc_info=True,
                    )
        except Exception:
            LOG.debug("vpc restart watcher exited", exc_info=True)

    threading.Thread(target=_loop, name="awsbox-vpc-restart", daemon=True).start()


def sync_container(
    container: str,
    subnet_id: str,
    account_id: str,
    region: str,
    vpc_id: str,
) -> None:
    try:
        _sync_container(container, subnet_id, account_id, region, vpc_id)
    except Exception:
        LOG.warning("vpc route sync failed for %s", container, exc_info=True)


def lambda_subnet_networks(executor: object) -> list[str]:
    """VPC bridge for a Lambda VpcConfig, resolved from subnet id when needed."""
    function_version = getattr(executor, "function_version", None)
    config = getattr(function_version, "config", None)
    vpc_config = getattr(config, "vpc_config", None) if config is not None else None
    if vpc_config is None:
        return []
    ident = getattr(function_version, "id", None)
    account_id = str(getattr(ident, "account", None) or "000000000000")
    region = str(getattr(ident, "region", None) or "us-east-1")
    vpc_id = getattr(vpc_config, "vpc_id", None) or None
    subnet_ids = list(getattr(vpc_config, "subnet_ids", None) or [])
    from localemu.services.ec2.docker.vpc_network import get_vpc_network_manager

    manager = get_vpc_network_manager()
    if not vpc_id:
        for subnet_id in subnet_ids:
            try:
                vpc_id = manager.get_vpc_id_for_subnet(subnet_id, account_id, region)
            except Exception:
                vpc_id = None
            if vpc_id:
                break
    if not vpc_id:
        return []
    try:
        manager.ensure_network_for_vpc(vpc_id)
    except Exception:
        LOG.debug("ensure VPC network %s failed", vpc_id, exc_info=True)
    return [f"localemu-vpc-{vpc_id}"]


def peered_vpc_ids(vpc_id: str) -> list[str]:
    from localemu.services.ec2.docker.vpc_network import get_vpc_network_manager

    manager = get_vpc_network_manager()
    found: list[str] = []
    with manager._lock:
        for peering in manager._peerings.values():
            if peering.get("vpc1_id") == vpc_id and peering.get("vpc2_id"):
                found.append(str(peering["vpc2_id"]))
            elif peering.get("vpc2_id") == vpc_id and peering.get("vpc1_id"):
                found.append(str(peering["vpc1_id"]))
    return found


def _sync_container(
    container: str,
    subnet_id: str,
    account_id: str,
    region: str,
    vpc_id: str,
) -> None:
    from localemu.services.ec2.docker.instance_routes import (
        _ec2_backend,
        _get_route_table,
        _resolve_route_table_for_subnet,
    )
    from localemu.services.ec2.docker.vpc_network import get_vpc_network_manager

    backend = _ec2_backend(account_id, region)
    if backend is None:
        return
    # Probe only — never apt/yum/apk install. Lambda Amazon Linux (and other
    # private images) hang for minutes on package managers without egress,
    # which burns LAMBDA_RUNTIME_ENVIRONMENT_TIMEOUT (#369). Route filter
    # and SG_IN/SG_OUT (#237) use the privileged alpine netns sidecar when
    # iptables is missing from the workload image.
    has_iptables = _container_has_iptables(container)
    if not has_iptables:
        LOG.info(
            "container %s has no iptables; VPC routes via netns sidecar",
            container,
        )
    _netns.sidecar = not has_iptables

    route_table_id = _resolve_route_table_for_subnet(subnet_id, account_id, region)
    route_table = _get_route_table(backend, route_table_id) if route_table_id else None
    routes = list((getattr(route_table, "routes", None) or {}).values()) if route_table else []

    allow: list[str] = []
    vpc = backend.get_vpc(vpc_id)
    vpc_cidr = _safe_cidr(getattr(vpc, "cidr_block", None))
    if vpc_cidr:
        allow.append(vpc_cidr)
    docker_cidr = _safe_cidr(get_vpc_network_manager().get_docker_cidr_for_vpc(vpc_id))
    if docker_cidr and docker_cidr not in allow:
        allow.append(docker_cidr)
    # #269: LocalEmu gateway IP (AWS_ENDPOINT_URL) is on the compose network,
    # not the VPC CIDR. Allow /32 so private subnets can still call the emulator.
    try:
        from localemu.services.ec2.docker.vpc_endpoint import _localemu_gateway

        gw_ip, _gw_net = _localemu_gateway()
        if gw_ip:
            allow.append(f"{gw_ip}/32")
    except Exception:
        LOG.debug("emulator gateway allow skipped", exc_info=True)

    default_kind: str | None = None
    nat_id: str | None = None
    igw_extra: list[str] = []
    peering_dests: dict[str, list[str]] = {}
    vpce_routes: list[tuple[str, str]] = []  # (cidr, via_ip)

    for route in routes:
        if getattr(route, "local", False):
            continue
        gateway_id = _gateway_id(route)
        vpce_id = _vpce_id(route, gateway_id)
        prefix = getattr(route, "destination_prefix_list", None)
        if vpce_id or prefix is not None:
            # Gateway endpoints have no ENI; moto installs a prefix-list
            # route to vpce-*. Add a /route via LocalEmu (or interface
            # proxy) so the fib can deliver — DNAT alone never runs when
            # there is no route to the prefix CIDR.
            cidrs = _prefix_list_cidrs(prefix, account_id, region)
            target = _vpce_proxy_ip(vpce_id) if vpce_id else None
            if not target:
                try:
                    from localemu.services.ec2.docker.vpc_endpoint import (
                        _localemu_gateway,
                    )

                    target, _net = _localemu_gateway()
                    target = _safe_ip(target)
                except Exception:
                    target = None
            for cidr in cidrs:
                allow.append(cidr)
                if target:
                    vpce_routes.append((cidr, target))
            if target:
                allow.append(f"{target}/32")
            if not cidrs:
                LOG.debug(
                    "gateway endpoint route on %s has no prefix list CIDRs",
                    route_table_id,
                )
            continue
        dest = _safe_cidr(getattr(route, "destination_cidr_block", None))
        pcx = getattr(route, "vpc_pcx", None)
        if pcx is not None and dest and getattr(pcx, "id", None):
            peering_dests.setdefault(str(pcx.id), []).append(dest)
            allow.append(dest)
            continue
        if not dest:
            continue
        nat = getattr(route, "nat_gateway", None)
        if nat is not None and dest == "0.0.0.0/0":
            default_kind = "nat"
            nat_id = str(getattr(nat, "id", "") or "") or None
            continue
        if gateway_id.startswith("igw-"):
            if dest == "0.0.0.0/0":
                default_kind = "igw"
            else:
                igw_extra.append(dest)
                allow.append(dest)

    # host.docker.internal (Lambda / ECS --add-host) stays reachable without
    # a default route; public internet hosts still require IGW/NAT.
    host_cidrs = _host_docker_internal_cidrs(container)
    allow.extend(host_cidrs)

    allow.extend(_sync_peering(container, vpc_id, peering_dests, backend))
    _apply_egress(container, default_kind, nat_id, igw_extra)
    # Fib route so ENETUNREACH does not fire before nat OUTPUT DNAT.
    _apply_vpce_routes(container, vpce_routes)
    _apply_vpce_dnat(container, vpce_routes)
    _apply_host_docker_routes(container, host_cidrs)
    _rebuild_mangle(container, allow, drop_rest=default_kind is None)
    LOG.info(
        "vpc routes %s subnet=%s default=%s vpce=%d",
        container,
        subnet_id,
        default_kind or "none",
        len(vpce_routes),
    )


def _sync_peering(
    container: str,
    vpc_id: str,
    peering_dests: dict[str, list[str]],
    backend: object,
) -> list[str]:
    from localemu.services.ec2.docker.container_routing import (
        add_peer_host_route,
        add_snat_for_pcx,
        alias_own_vpc_ip_on_pcx,
        del_peer_host_route,
        resolve_pcx_iface,
    )
    from localemu.services.ec2.docker.vpc_network import get_vpc_network_manager
    from localemu.utils.docker_utils import DOCKER_CLIENT

    manager = get_vpc_network_manager()
    with manager._lock:
        active = []
        for peering_id, peering in manager._peerings.items():
            if peering.get("vpc1_id") == vpc_id:
                peer_vpc_id = peering.get("vpc2_id")
            elif peering.get("vpc2_id") == vpc_id:
                peer_vpc_id = peering.get("vpc1_id")
            else:
                continue
            peer_names = list((manager._vpcs.get(peer_vpc_id) or {}).get("containers", set()))
            active.append(
                (
                    str(peering_id),
                    str(peer_vpc_id or ""),
                    str(peering.get("network_name") or f"localemu-pcx-{peering_id}"),
                    peer_names,
                )
            )

    allowed_ips: list[str] = []
    own_net = f"localemu-vpc-{vpc_id}"
    for peering_id, peer_vpc_id, peering_net, peer_names in active:
        if not peer_vpc_id:
            continue
        _connect(peering_net, container)
        for peer_name in peer_names:
            if str(peer_name).startswith("localemu-ec2-"):
                _connect(peering_net, str(peer_name))
        dests = peering_dests.get(peering_id, [])
        peer_cidr = ""
        try:
            peer_vpc = backend.get_vpc(peer_vpc_id)
            peer_cidr = str(getattr(peer_vpc, "cidr_block", "") or "")
        except Exception:
            peer_cidr = ""
        try:
            own_vpc_ip = DOCKER_CLIENT.get_container_ipv4_for_network(container, own_net)
            own_pcx_ip = DOCKER_CLIENT.get_container_ipv4_for_network(container, peering_net)
        except Exception:
            own_vpc_ip = own_pcx_ip = None
        # Lambda images lack `ip`; resolve_pcx_iface exec fails — use sidecar.
        iface = _iface_for_network(container, peering_net)
        if not iface:
            import time
            time.sleep(0.2)
            iface = _iface_for_network(container, peering_net)
            if not iface:
                iface = resolve_pcx_iface(container, peering_net)
        own_vpc_ip = _safe_ip(own_vpc_ip)
        own_pcx_ip = _safe_ip(own_pcx_ip)
        if iface and own_vpc_ip and own_pcx_ip:
            alias_own_vpc_ip_on_pcx(container, iface, own_vpc_ip)
            add_snat_for_pcx(container, iface, own_pcx_ip)
            _sh(
                container,
                f"ip addr add {own_vpc_ip}/32 dev {iface} 2>/dev/null || true; "
                f"iptables -t nat -C POSTROUTING -o {iface} -j SNAT --to-source {own_pcx_ip} "
                f"2>/dev/null || iptables -t nat -A POSTROUTING -o {iface} "
                f"-j SNAT --to-source {own_pcx_ip}",
            )
        peer_net = f"localemu-vpc-{peer_vpc_id}"
        # Prefer tracked EC2 names; also scan anyone on the peer VPC bridge
        # (smoke / custom peers) so Lambda can reach them over pcx.
        scan_names = {str(n) for n in peer_names if str(n).startswith("localemu-ec2-")}
        try:
            info = DOCKER_CLIENT.inspect_network(peer_net) or {}
            for meta in (info.get("Containers") or {}).values():
                name = str((meta or {}).get("Name") or "").lstrip("/")
                if name and name != container:
                    scan_names.add(name)
        except Exception:
            LOG.debug("peer container scan failed for %s", peer_net, exc_info=True)
        for peer_name in scan_names:
            try:
                peer_vpc_ip = DOCKER_CLIENT.get_container_ipv4_for_network(peer_name, peer_net)
                peer_pcx_ip = DOCKER_CLIENT.get_container_ipv4_for_network(peer_name, peering_net)
            except Exception:
                continue
            peer_vpc_ip = _safe_ip(peer_vpc_ip)
            peer_pcx_ip = _safe_ip(peer_pcx_ip)
            if not peer_vpc_ip or not peer_pcx_ip or not iface:
                continue
            # #204: only when the route table has a pcx dest covering the peer.
            covered = any(_covers(dest, peer_cidr, peer_vpc_ip) for dest in dests)
            if covered:
                # Prefer LocalEmu helper; also apply via _sh so Lambda
                # sidecars (no in-image iptables) still get the DNAT.
                add_peer_host_route(container, iface, peer_vpc_ip, peer_pcx_ip)
                _sh(
                    container,
                    "iptables -t nat -C OUTPUT "
                    f"-d {peer_vpc_ip}/32 -j DNAT --to-destination {peer_pcx_ip} "
                    "2>/dev/null || iptables -t nat -A OUTPUT "
                    f"-d {peer_vpc_ip}/32 -j DNAT --to-destination {peer_pcx_ip}; "
                    f"ip route replace {peer_vpc_ip}/32 via {peer_pcx_ip} dev {iface} "
                    f"2>/dev/null || ip route replace {peer_vpc_ip}/32 via {peer_pcx_ip}",
                )
                allowed_ips.append(f"{peer_vpc_ip}/32")
            else:
                del_peer_host_route(container, iface, peer_vpc_ip, peer_pcx_ip)
                _sh(
                    container,
                    "iptables -t nat -D OUTPUT "
                    f"-d {peer_vpc_ip}/32 -j DNAT --to-destination {peer_pcx_ip} "
                    "2>/dev/null || true; "
                    f"ip route del {peer_vpc_ip}/32 2>/dev/null || true",
                )
        # Fib for route-table pcx destinations only (not the whole peer VPC
        # CIDR) so DeleteRoute fails closed (#204 sad path).
        pcx_gw = _network_gateway(peering_net)
        if iface and pcx_gw:
            for dest in dests:
                safe = _safe_cidr(dest)
                if not safe:
                    continue
                _sh(
                    container,
                    f"ip route replace {safe} via {pcx_gw} dev {iface} 2>/dev/null || "
                    f"ip route replace {safe} via {pcx_gw}",
                )
            # Drop a stale whole-VPC fib if the RT no longer has that dest.
            if peer_cidr and peer_cidr not in dests:
                safe_peer = _safe_cidr(peer_cidr)
                if safe_peer:
                    _sh(
                        container,
                        f"ip route del {safe_peer} 2>/dev/null || true",
                    )
    return allowed_ips


def _apply_egress(
    container: str,
    default_kind: str | None,
    nat_id: str | None,
    igw_extra: list[str],
) -> None:
    from localemu.utils.docker_utils import DOCKER_CLIENT

    keep = f"localemu-nat-bridge-{nat_id}" if default_kind == "nat" and nat_id else None
    try:
        networks = DOCKER_CLIENT.get_networks(container)
    except Exception:
        networks = []
    for network in networks:
        if network.startswith("localemu-nat-bridge-") and network != keep:
            try:
                DOCKER_CLIENT.disconnect_container_from_network(network, container)
            except Exception:
                LOG.debug("disconnect %s from %s failed", container, network, exc_info=True)
    _sh(
        container,
        f"marker={_MARKER}; "
        "if [ -f \"$marker\" ] && command -v ip >/dev/null 2>&1; then "
        "while read -r cidr; do [ -n \"$cidr\" ] && ip route del \"$cidr\" 2>/dev/null || true; "
        "done < \"$marker\"; fi; rm -f \"$marker\"; "
        "while ip route del default 2>/dev/null; do :; done; true",
    )
    if default_kind == "nat" and keep:
        _connect(keep, container)
        _set_default(container, keep)
    elif default_kind == "igw":
        _connect(_PUBPORT, container)
        if not _set_default(container, _PUBPORT):
            # Lambda / bridge tasks may lack pubport; use compose/bridge gw.
            _set_default_any(container)
    if not igw_extra:
        return
    gateway, iface = _gw_iface(container, _PUBPORT)
    if not gateway or not iface:
        return
    lines = ["mkdir -p /var/lib/localemu", f": > {_MARKER}"]
    for cidr in igw_extra:
        lines.append(f"ip route replace {cidr} via {gateway} dev {iface}")
        lines.append(f"echo {cidr} >> {_MARKER}")
    lines.append("true")
    _sh(container, "; ".join(lines))


def _rebuild_mangle(container: str, allow: list[str], drop_rest: bool) -> None:
    cidrs: list[str] = []
    for cidr in allow:
        safe = _safe_cidr(cidr)
        if safe and safe not in cidrs:
            cidrs.append(safe)
    parts = [
        "command -v iptables >/dev/null 2>&1 || exit 0",
        f"iptables -t mangle -N {_CHAIN} 2>/dev/null || true",
        f"iptables -t mangle -F {_CHAIN}",
        f"iptables -t mangle -C OUTPUT -j {_CHAIN} 2>/dev/null || iptables -t mangle -I OUTPUT 1 -j {_CHAIN}",
        f"iptables -t mangle -A {_CHAIN} -m state --state ESTABLISHED,RELATED -j ACCEPT",
        f"iptables -t mangle -A {_CHAIN} -d 127.0.0.0/8 -j ACCEPT",
        f"iptables -t mangle -A {_CHAIN} -d 169.254.0.0/16 -j ACCEPT",
    ]
    for cidr in cidrs:
        parts.append(f"iptables -t mangle -A {_CHAIN} -d {cidr} -j ACCEPT")
    if drop_rest:
        parts.append(f"iptables -t mangle -A {_CHAIN} -j DROP")
    # Fail open (empty chain, no DROP) if a rule cannot be installed.
    _sh(container, " && ".join(parts))


def _apply_vpce_routes(container: str, pairs: list[tuple[str, str]]) -> None:
    """Install fib routes for prefix CIDRs so OUTPUT DNAT can run."""
    lines = [
        "command -v ip >/dev/null 2>&1 || exit 0",
        "mkdir -p /var/lib/localemu",
        "marker=/var/lib/localemu/awsbox-vpce-routes.txt",
        'if [ -f "$marker" ]; then while read -r cidr; do '
        '[ -n "$cidr" ] && ip route del "$cidr" 2>/dev/null || true; done < "$marker"; fi',
        ': > "$marker"',
    ]
    seen: set[tuple[str, str]] = set()
    for cidr, via_ip in pairs:
        safe = _safe_cidr(cidr)
        tip = _safe_ip(via_ip)
        if not safe or not tip:
            continue
        key = (safe, tip)
        if key in seen:
            continue
        seen.add(key)
        # via LocalEmu: first-hop so the kernel accepts the dest; DNAT
        # then rewrites to the LocalEmu /32 before the packet leaves.
        lines.append(f"ip route replace {safe} via {tip}")
        lines.append(f'echo {safe} >> "$marker"')
    lines.append("true")
    _sh(container, "; ".join(lines))


def _apply_vpce_dnat(container: str, pairs: list[tuple[str, str]]) -> None:
    """DNAT gateway-endpoint prefix CIDRs to LocalEmu / VPCE proxy :4566."""
    parts = [
        "command -v iptables >/dev/null 2>&1 || exit 0",
        f"iptables -t nat -N {_VPCE_CHAIN} 2>/dev/null || true",
        f"iptables -t nat -F {_VPCE_CHAIN}",
        f"iptables -t nat -C OUTPUT -j {_VPCE_CHAIN} 2>/dev/null || iptables -t nat -I OUTPUT 1 -j {_VPCE_CHAIN}",
    ]
    seen: set[tuple[str, str]] = set()
    for cidr, proxy_ip in pairs:
        safe = _safe_cidr(cidr)
        tip = _safe_ip(proxy_ip)
        if not safe or not tip:
            continue
        key = (safe, tip)
        if key in seen:
            continue
        seen.add(key)
        for port in ("443", "80", "4566"):
            parts.append(
                f"iptables -t nat -A {_VPCE_CHAIN} -d {safe} -p tcp --dport {port} "
                f"-j DNAT --to-destination {tip}:4566"
            )
    _sh(container, " && ".join(parts))


def _vpce_id(route: object, gateway_id: str) -> str | None:
    if gateway_id.startswith("vpce-"):
        return gateway_id
    raw = getattr(route, "vpc_endpoint_id", None)
    if isinstance(raw, str) and raw.startswith("vpce-"):
        return raw
    return None


def _vpce_proxy_ip(endpoint_id: str) -> str | None:
    try:
        from localemu.services.ec2.docker.vpc_endpoint import get_vpc_endpoint_manager

        return _safe_ip(get_vpc_endpoint_manager().get_endpoint_ip(endpoint_id))
    except Exception:
        LOG.debug("vpce proxy lookup failed for %s", endpoint_id, exc_info=True)
        return None


def _prefix_list_cidrs(prefix: object, account_id: str, region: str) -> list[str]:
    if prefix is None:
        return []
    entries = None
    version = getattr(prefix, "version", None)
    raw_entries = getattr(prefix, "entries", None)
    if isinstance(raw_entries, dict):
        if version is not None and version in raw_entries:
            entries = raw_entries[version]
        elif raw_entries:
            entries = list(raw_entries.values())[-1]
    elif isinstance(raw_entries, list):
        entries = raw_entries
    if not entries:
        pl_id = getattr(prefix, "id", None) or getattr(prefix, "prefix_list_id", None)
        if pl_id:
            try:
                from localemu.services.ec2.docker.instance_routes import _ec2_backend

                backend = _ec2_backend(account_id, region)
                listed = getattr(backend, "managed_prefix_lists", {}).get(pl_id) if backend else None
                if listed is not None:
                    return _prefix_list_cidrs(listed, account_id, region)
            except Exception:
                LOG.debug("prefix list %s expand failed", pl_id, exc_info=True)
        return []
    out: list[str] = []
    for item in entries:
        if isinstance(item, dict):
            cidr = _safe_cidr(item.get("Cidr") or item.get("cidr"))
        else:
            cidr = _safe_cidr(getattr(item, "cidr", None) or getattr(item, "Cidr", None))
        if cidr and cidr not in out:
            out.append(cidr)
    return out


def _host_docker_internal_cidrs(container: str) -> list[str]:
    """Allow mapped host.docker.internal without opening the public internet.

    Read the workload ``/etc/hosts`` (not a netns sidecar — that FS is empty).
    ExtraHosts often still says ``host-gateway``; the resolved IP is in hosts.
    """
    from localemu.utils.docker_utils import DOCKER_CLIENT

    cidrs: list[str] = []
    seen: set[str] = set()

    def _add(ip: str | None) -> None:
        tip = _safe_ip(ip)
        if not tip or tip in seen:
            return
        seen.add(tip)
        cidrs.append(f"{tip}/32")

    try:
        result = DOCKER_CLIENT.exec_in_container(
            container,
            [
                "sh",
                "-c",
                "grep -E '[[:space:]]host\\.docker\\.internal([[:space:]]|$)' "
                "/etc/hosts 2>/dev/null | awk '{print $1}'",
            ],
            user="0",
        )
        raw = result[0] if isinstance(result, tuple) and result else result
        text = (
            raw.decode("utf-8", errors="replace")
            if isinstance(raw, bytes)
            else str(raw or "")
        )
        for line in text.splitlines():
            _add(line.strip())
    except Exception:
        LOG.debug("host.docker.internal hosts read failed for %s", container, exc_info=True)

    if not cidrs:
        try:
            inspected = DOCKER_CLIENT.inspect_container(container) or {}
            for entry in (inspected.get("HostConfig") or {}).get("ExtraHosts") or []:
                text = str(entry)
                if not text.startswith("host.docker.internal:"):
                    continue
                value = text.split(":", 1)[1].strip()
                if value and value != "host-gateway":
                    _add(value)
        except Exception:
            LOG.debug("ExtraHosts inspect failed for %s", container, exc_info=True)

    return cidrs


def _apply_host_docker_routes(container: str, host_cidrs: list[str]) -> None:
    """Fib /32 so host.docker.internal is reachable without a default route."""
    if not host_cidrs:
        return
    from localemu.utils.docker_utils import DOCKER_CLIENT

    gateway = None
    iface = None
    try:
        networks = list(DOCKER_CLIENT.get_networks(container) or [])
    except Exception:
        networks = []
    for network in networks:
        if network.startswith("localemu-vpc-") or network.startswith("localemu-pcx-"):
            continue
        if network.startswith("localemu-nat-bridge-"):
            continue
        gateway, iface = _gw_iface(container, network)
        if gateway:
            break
    if not gateway:
        return
    for cidr in host_cidrs:
        safe = _safe_cidr(cidr)
        if not safe:
            continue
        if iface:
            _sh(
                container,
                f"ip route replace {safe} via {gateway} dev {iface} 2>/dev/null || "
                f"ip route replace {safe} via {gateway}",
            )
        else:
            _sh(container, f"ip route replace {safe} via {gateway}")


def _sh_out(container: str, script: str) -> str:
    if getattr(_netns, "sidecar", False):
        return _sh_out_netns(container, script)
    from localemu.utils.docker_utils import DOCKER_CLIENT

    try:
        result = DOCKER_CLIENT.exec_in_container(
            container, ["sh", "-c", script], user="0"
        )
    except Exception:
        LOG.debug("exec out in %s failed; trying netns sidecar", container, exc_info=True)
        return _sh_out_netns(container, script)
    if isinstance(result, tuple) and result:
        raw = result[0]
    else:
        raw = result
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="replace")
    return str(raw or "")


def _iface_for_network(container: str, network: str) -> str | None:
    """MAC-match iface; works for Lambda via netns sidecar (no in-image ``ip``)."""
    from localemu.utils.docker_utils import DOCKER_CLIENT

    if not container or not network:
        return None
    try:
        inspected = DOCKER_CLIENT.inspect_container(container) or {}
    except Exception:
        return None
    nets = (
        (inspected.get("NetworkSettings") or {}).get("Networks") or {}
    )
    net_info = nets.get(network) or {}
    mac = str(net_info.get("MacAddress") or "").lower()
    if not mac:
        return None
    text = _sh_out(container, "ip -o link show")
    for line in (text or "").splitlines():
        if mac not in line.lower():
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        iface_name = parts[1].rstrip(":")
        iface = iface_name.split("@", 1)[0]
        return iface if _safe_iface(iface) else None
    return None


def _set_default(container: str, network: str) -> bool:
    gateway, iface = _gw_iface(container, network)
    if not gateway:
        LOG.debug("no gateway for %s on %s", container, network)
        return False
    if iface:
        _sh(container, f"ip route replace default via {gateway} dev {iface}")
    else:
        _sh(container, f"ip route replace default via {gateway}")
    return True


def _set_default_any(container: str) -> None:
    """Pick a non-VPC / non-pcx gateway already attached to the container."""
    from localemu.utils.docker_utils import DOCKER_CLIENT

    preferred: list[str] = []
    try:
        from localemu.services.ec2.docker.vpc_endpoint import _localemu_gateway

        _ip, gw_net = _localemu_gateway()
        if gw_net:
            preferred.append(str(gw_net))
    except Exception:
        pass
    try:
        networks = list(DOCKER_CLIENT.get_networks(container) or [])
    except Exception:
        networks = []
    ordered = preferred + [n for n in networks if n not in preferred]
    for network in ordered:
        if network.startswith("localemu-vpc-") or network.startswith("localemu-pcx-"):
            continue
        if network.startswith("localemu-nat-bridge-"):
            continue
        if network.startswith("localemu-pubport"):
            continue
        if _set_default(container, network):
            LOG.info("default route for %s via network %s", container, network)
            return


def _gw_iface(container: str, network: str) -> tuple[str | None, str | None]:
    import time

    from localemu.services.ec2.docker.iface_resolver import resolve_iface_for_network

    gateway = _network_gateway(network)
    iface = _iface_for_network(container, network) or resolve_iface_for_network(
        container, network
    )
    if gateway and iface:
        return gateway, iface
    time.sleep(0.2)
    if not gateway:
        gateway = _network_gateway(network)
    if not iface:
        iface = _iface_for_network(container, network) or resolve_iface_for_network(
            container, network
        )
    if iface and not _safe_iface(iface):
        return gateway, None
    return gateway, iface


def _network_gateway(network: str) -> str | None:
    from localemu.utils.docker_utils import DOCKER_CLIENT

    try:
        info = DOCKER_CLIENT.inspect_network(network) or {}
    except Exception:
        return None
    configs = (info.get("IPAM") or {}).get("Config") or []
    if not isinstance(configs, list):
        return None
    for cfg in configs:
        if not isinstance(cfg, dict):
            continue
        gateway = _safe_ip(cfg.get("Gateway"))
        if gateway:
            return gateway
        subnet = cfg.get("Subnet")
        if not subnet:
            continue
        try:
            hosts = ipaddress.ip_network(str(subnet), strict=False).hosts()
            return str(next(hosts))
        except (ValueError, StopIteration):
            continue
    return None


def _connect(network: str, container: str) -> None:
    from localemu.utils.docker_utils import DOCKER_CLIENT

    try:
        DOCKER_CLIENT.connect_container_to_network(network, container)
    except Exception:
        LOG.debug("connect %s to %s skipped", container, network, exc_info=True)


def _container_has_iptables(container: str) -> bool:
    """True when iptables is already runnable — never tries to install it."""
    from localemu.utils.docker_utils import DOCKER_CLIENT

    try:
        DOCKER_CLIENT.exec_in_container(
            container,
            [
                "sh",
                "-c",
                "command -v iptables >/dev/null && iptables -V >/dev/null",
            ],
        )
        return True
    except Exception:
        return False


def _sh(container: str, script: str) -> None:
    # user=0: non-root images still need route/iptables changes in this netns.
    # Lambda Amazon Linux images often lack iptables; use an alpine sidecar
    # sharing the target network namespace (#230).
    if getattr(_netns, "sidecar", False):
        _sh_netns(container, script)
        return
    from localemu.utils.docker_utils import DOCKER_CLIENT

    try:
        DOCKER_CLIENT.exec_in_container(
            container, ["sh", "-c", script], user="0"
        )
        return
    except Exception:
        LOG.debug("exec in %s failed; trying netns sidecar", container, exc_info=True)
    _sh_netns(container, script)


_RT_IMAGE = "localemu/awsbox-rt:latest"
_RT_DOCKERFILE = """\
FROM alpine:3.19
RUN apk add --no-cache iptables iproute2 \\
    && rm -rf /var/cache/apk/*
LABEL org.localemu.image-role="awsbox-route-sidecar"
"""
_rt_image_lock = threading.Lock()


def _ensure_rt_image() -> str:
    """Alpine with iptables/iproute2 — sidecar has no outbound for apk."""
    from localemu.utils.docker_utils import DOCKER_CLIENT

    try:
        DOCKER_CLIENT.inspect_image(_RT_IMAGE)
        return _RT_IMAGE
    except Exception:
        pass
    with _rt_image_lock:
        try:
            DOCKER_CLIENT.inspect_image(_RT_IMAGE)
            return _RT_IMAGE
        except Exception:
            pass
        import tempfile

        try:
            with tempfile.TemporaryDirectory(prefix="awsbox-rt-img-") as ctx:
                path = os.path.join(ctx, "Dockerfile")
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(_RT_DOCKERFILE)
                DOCKER_CLIENT.build_image(
                    dockerfile_path=path,
                    image_name=_RT_IMAGE,
                    context_path=ctx,
                )
            return _RT_IMAGE
        except Exception:
            LOG.warning("awsbox-rt image build failed; using alpine + apk", exc_info=True)
            return "alpine:3.19"


def _sh_netns(container: str, script: str) -> None:
    """Run ``script`` in ``container``'s netns via a privileged alpine sidecar."""
    _sh_out_netns(container, script)


def _sh_out_netns(container: str, script: str) -> str:
    """Run ``script`` in ``container``'s netns; return stdout."""
    from localemu.utils.docker_utils import DOCKER_CLIENT

    image = _ensure_rt_image()
    full = script
    if image == "alpine:3.19":
        full = "apk add --no-cache iptables iproute2 >/dev/null 2>&1; " + script
    try:
        result = DOCKER_CLIENT.run_container(
            image,
            command=["sh", "-c", full],
            additional_flags=f"--network container:{container}",
            privileged=True,
            remove=True,
        )
    except Exception:
        LOG.debug("netns sidecar for %s failed", container, exc_info=True)
        return ""
    if isinstance(result, tuple) and result:
        raw = result[0]
    else:
        raw = result
    if isinstance(raw, bytes):
        return raw.decode("utf-8", errors="replace")
    return str(raw or "")


def _running(container: str) -> bool:
    from localemu.utils.docker_utils import DOCKER_CLIENT

    try:
        return bool(DOCKER_CLIENT.is_container_running(container))
    except Exception:
        return False


def _find_backend(
    vpc_id: str,
    account_id: str | None,
    region: str | None,
) -> tuple[str | None, str | None, object | None]:
    from localemu.services.ec2.docker.instance_routes import _ec2_backend

    if account_id and region:
        backend = _ec2_backend(account_id, region)
        if backend is not None and _backend_has_vpc(backend, vpc_id):
            return account_id, region, backend
    import moto.backends as moto_backends

    root = moto_backends.get_backend("ec2")
    if isinstance(root, dict):
        for account, regions in root.items():
            if not isinstance(regions, dict):
                continue
            for found_region, backend in regions.items():
                if _backend_has_vpc(backend, vpc_id):
                    return str(account), str(found_region), backend
    return account_id, region, None


def _backend_has_vpc(backend: object, vpc_id: str) -> bool:
    vpcs = getattr(backend, "vpcs", None)
    if isinstance(vpcs, dict) and vpc_id in vpcs:
        return True
    try:
        return backend.get_vpc(vpc_id) is not None
    except Exception:
        return False


def _covers(dest: str, peer_cidr: str, peer_ip: str) -> bool:
    try:
        dest_net = ipaddress.ip_network(dest, strict=False)
        if ipaddress.ip_address(peer_ip) in dest_net:
            return True
        if not peer_cidr:
            return False
        peer_net = ipaddress.ip_network(peer_cidr, strict=False)
    except ValueError:
        return False
    return bool(peer_net.subnet_of(dest_net))


def _gateway_id(route: object) -> str:
    gateway = getattr(route, "gateway", None)
    if gateway is None:
        return ""
    return str(getattr(gateway, "id", "") or "")


def _safe_cidr(value: object) -> str | None:
    if not isinstance(value, str) or "/" not in value:
        return None
    try:
        network = ipaddress.ip_network(value, strict=False)
    except ValueError:
        return None
    if network.version != 4:
        return None
    return str(network)


def _safe_ip(value: object) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return None
    if address.version != 4:
        return None
    return str(address)


def _safe_iface(name: str) -> bool:
    return bool(name) and all(ch.isalnum() or ch in "._-" for ch in name)
