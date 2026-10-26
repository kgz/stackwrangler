"""Apply subnet route tables to workload containers.

EC2's primary Docker network is the non-internal pubport bridge, so a
private subnet still has a default route unless we remove it. Peering
and NAT are attached for the whole VPC; this module keeps them in step
with the subnet route table.

Packets are filtered in mangle OUTPUT, which runs before nat OUTPUT.
That sees the original destination (the peer VPC IP) rather than the
peering-bridge address the DNAT rule rewrites it to.
"""

from __future__ import annotations

import ipaddress
import logging

LOG = logging.getLogger("localemu.awsbox.vpc_routing")

_PUBPORT = "localemu-pubport-br"
_MARKER = "/var/lib/localemu/awsbox-igw-routes.txt"
_CHAIN = "AWSBOX-RT"


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


def sync_workload(container: str, subnet_id: str, account_id: str, region: str) -> None:
    """ECS awsvpc (and any non-EC2 workload) on a subnet."""
    from localemu.services.ec2.docker.instance_routes import _ec2_backend, _get_subnet

    if not container or not subnet_id or not account_id or not region:
        return
    backend = _ec2_backend(account_id, region)
    if backend is None:
        return
    subnet = _get_subnet(backend, subnet_id)
    vpc_id = getattr(subnet, "vpc_id", None) if subnet is not None else None
    if not vpc_id:
        return
    sync_container(container, subnet_id, account_id, region, vpc_id)


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

    for route in routes:
        if getattr(route, "local", False):
            continue
        if getattr(route, "destination_prefix_list", None) or getattr(route, "vpc_endpoint_id", None):
            LOG.debug("gateway endpoint route on %s is not enforced", route_table_id)
        gateway_id = _gateway_id(route)
        if gateway_id.startswith("vpce-"):
            LOG.debug("gateway endpoint %s on %s is not enforced", gateway_id, route_table_id)
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

    allow.extend(_sync_peering(container, vpc_id, peering_dests, backend))
    _apply_egress(container, default_kind, nat_id, igw_extra)
    _rebuild_mangle(container, allow, drop_rest=default_kind is None)
    LOG.info(
        "vpc routes %s subnet=%s default=%s",
        container,
        subnet_id,
        default_kind or "none",
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
        iface = resolve_pcx_iface(container, peering_net)
        if not iface:
            import time
            time.sleep(0.2)
            iface = resolve_pcx_iface(container, peering_net)
        own_vpc_ip = _safe_ip(own_vpc_ip)
        own_pcx_ip = _safe_ip(own_pcx_ip)
        if iface and own_vpc_ip and own_pcx_ip:
            alias_own_vpc_ip_on_pcx(container, iface, own_vpc_ip)
            add_snat_for_pcx(container, iface, own_pcx_ip)
        peer_net = f"localemu-vpc-{peer_vpc_id}"
        for peer_name in peer_names:
            if not str(peer_name).startswith("localemu-ec2-"):
                continue
            try:
                peer_vpc_ip = DOCKER_CLIENT.get_container_ipv4_for_network(peer_name, peer_net)
                peer_pcx_ip = DOCKER_CLIENT.get_container_ipv4_for_network(peer_name, peering_net)
            except Exception:
                continue
            peer_vpc_ip = _safe_ip(peer_vpc_ip)
            peer_pcx_ip = _safe_ip(peer_pcx_ip)
            if not peer_vpc_ip or not peer_pcx_ip or not iface:
                continue
            covered = any(_covers(dest, peer_cidr, peer_vpc_ip) for dest in dests)
            if covered:
                add_peer_host_route(container, iface, peer_vpc_ip, peer_pcx_ip)
                allowed_ips.append(f"{peer_vpc_ip}/32")
            else:
                del_peer_host_route(container, iface, peer_vpc_ip, peer_pcx_ip)
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
        _set_default(container, _PUBPORT)
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


def _set_default(container: str, network: str) -> None:
    gateway, iface = _gw_iface(container, network)
    if not gateway or not iface:
        LOG.debug("no gateway for %s on %s", container, network)
        return
    _sh(container, f"ip route replace default via {gateway} dev {iface}")


def _gw_iface(container: str, network: str) -> tuple[str | None, str | None]:
    import time

    from localemu.services.ec2.docker.iface_resolver import resolve_iface_for_network

    gateway = _network_gateway(network)
    iface = resolve_iface_for_network(container, network)
    if gateway and iface:
        return gateway, iface
    time.sleep(0.2)
    if not gateway:
        gateway = _network_gateway(network)
    if not iface:
        iface = resolve_iface_for_network(container, network)
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


def _sh(container: str, script: str) -> None:
    # user=0: non-root images still need route/iptables changes in this netns.
    from localemu.utils.docker_utils import DOCKER_CLIENT

    try:
        DOCKER_CLIENT.exec_in_container(
            container, ["sh", "-c", script], user="0"
        )
    except Exception:
        LOG.debug("exec in %s failed", container, exc_info=True)


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
