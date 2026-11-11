"""Security group iptables for ECS awsvpc tasks, RDS, and VPC Lambda.

EC2 already programs SG_IN / SG_OUT from moto rules plus AddressIndex
membership. This module registers the other workload ENIs in that index,
runs the same apply, and refreshes rules when an SG or prefix list changes.

Lambda (and any image without iptables) gets SG_IN / SG_OUT via the alpine
netns sidecar used for VPC routes — never apt/yum into the workload image.
"""

from __future__ import annotations

import logging
import threading
from dataclasses import dataclass
from types import SimpleNamespace

LOG = logging.getLogger("localemu.awsbox.sg_enforcement")

_lock = threading.Lock()
_ctx = threading.local()
_installed = False


@dataclass
class Workload:
    container: str
    eni_id: str
    account_id: str
    region: str
    sg_ids: list[str]
    kind: str
    vpc_id: str = ""


_workloads: dict[str, Workload] = {}


def install() -> None:
    global _installed
    if _installed:
        return
    _installed = True
    _patch_rule_builder()
    _patch_reapply()
    _patch_prefix_lists()
    _patch_rds()
    _patch_rds_caps()
    LOG.info(
        "awsbox SG enforcement installed (ECS awsvpc + RDS + VPC Lambda + prefix lists)"
    )


def attach_container(
    docker_name: str,
    subnet_ids: list[str] | None,
    sg_ids: list[str] | None,
    account_id: str,
    region: str,
    kind: str,
) -> None:
    """Register one workload ENI and program its iptables."""
    install()
    account_id = account_id or "000000000000"
    region = region or "us-east-1"
    if not docker_name:
        return
    subnet_id = (subnet_ids or [None])[0]
    vpc_id = _vpc_for_subnet(subnet_id, account_id, region) if subnet_id else None
    if not vpc_id:
        LOG.debug("SG attach %s: no VPC for subnets %s", docker_name, subnet_ids)
        return
    groups = [sg for sg in (sg_ids or []) if sg]
    if not groups:
        groups = _default_sg_ids(vpc_id, account_id, region)
    ip = _container_vpc_ip(docker_name, vpc_id, None)
    if not ip:
        LOG.warning("SG attach %s: no IP on localemu-vpc-%s", docker_name, vpc_id)
        return
    eni_id = _eni_id(kind, docker_name)
    _upsert_eni(
        eni_id=eni_id,
        vpc_id=vpc_id,
        subnet_id=subnet_id or "",
        ip=ip,
        sg_ids=groups,
        instance_id=f"{kind}:{docker_name}",
    )
    _remember(docker_name, eni_id, account_id, region, groups, kind, vpc_id)
    _apply(docker_name, groups, account_id, region)
    _refresh_referencers(groups, account_id, region)


def release_container(docker_name: str) -> None:
    with _lock:
        wl = _workloads.pop(docker_name, None)
    if wl is None:
        return
    try:
        from localemu.services.ec2.docker.address_index import get_address_index

        get_address_index().delete_eni(wl.eni_id)
    except Exception:
        LOG.debug("SG release %s: ENI delete failed", docker_name, exc_info=True)
    _refresh_referencers(wl.sg_ids, wl.account_id, wl.region)


def _patch_rule_builder() -> None:
    import localemu.services.ec2.docker.sg_iptables as sg_iptables

    original_build = sg_iptables._build_chain_rules
    original_collect = sg_iptables._collect_rules

    def _build_chain_rules(sg_rules, chain, is_egress):
        account_id = getattr(_ctx, "account_id", None)
        region = getattr(_ctx, "region", None)
        if account_id and region:
            sg_rules = _expand_prefix_lists(sg_rules, account_id, region)
        return original_build(sg_rules, chain, is_egress)

    def _collect_rules(sg_ids, account_id, region):
        _ctx.account_id = account_id
        _ctx.region = region
        return original_collect(sg_ids, account_id, region)

    sg_iptables._build_chain_rules = _build_chain_rules
    sg_iptables._collect_rules = _collect_rules


def _patch_reapply() -> None:
    import localemu.services.ec2.docker.sg_reapply as sg_reapply

    original = sg_reapply.reapply_sg_for_sg_id

    def reapply_sg_for_sg_id(sg_id, account_id, region):
        applied = original(sg_id, account_id, region)
        with _lock:
            targets = [
                wl
                for wl in _workloads.values()
                if wl.account_id == account_id
                and wl.region == region
                and sg_id in wl.sg_ids
            ]
        for wl in targets:
            if _apply(wl.container, wl.sg_ids, account_id, region):
                applied += 1
        return applied

    sg_reapply.reapply_sg_for_sg_id = reapply_sg_for_sg_id


def _patch_prefix_lists() -> None:
    from moto.ec2.models.managed_prefixes import ManagedPrefixListBackend

    original = ManagedPrefixListBackend.modify_managed_prefix_list

    def modify_managed_prefix_list(
        self,
        add_entry,
        remove_entry,
        prefix_list_id=None,
        current_version=None,
        prefix_list_name=None,
    ):
        result = original(
            self,
            add_entry,
            remove_entry,
            prefix_list_id,
            current_version,
            prefix_list_name,
        )
        if prefix_list_id:
            try:
                _reapply_prefix_list(
                    prefix_list_id,
                    getattr(self, "account_id", None) or "000000000000",
                    getattr(self, "region_name", None) or "us-east-1",
                )
            except Exception:
                LOG.warning(
                    "prefix list %s reapply failed", prefix_list_id, exc_info=True
                )
        return result

    ManagedPrefixListBackend.modify_managed_prefix_list = modify_managed_prefix_list


def _patch_rds_caps() -> None:
    from localemu.utils.docker_utils import DOCKER_CLIENT

    original = DOCKER_CLIENT.create_container_from_config

    def create_container_from_config(config):
        labels = getattr(config, "labels", None) or {}
        if labels.get("localemu.service") == "rds":
            caps = list(getattr(config, "cap_add", None) or [])
            if "NET_ADMIN" not in caps:
                caps.append("NET_ADMIN")
            config.cap_add = caps
        return original(config)

    DOCKER_CLIENT.create_container_from_config = create_container_from_config


def _patch_rds() -> None:
    from localemu.services.rds.docker.db_manager import DockerDbManager

    original_create = DockerDbManager.create_db_instance
    original_delete = DockerDbManager.delete_db_instance

    def create_db_instance(self, *args, **kwargs):
        info = original_create(self, *args, **kwargs)
        try:
            _attach_rds(info)
        except Exception:
            LOG.warning(
                "RDS SG attach failed for %s",
                getattr(info, "db_instance_id", "?"),
                exc_info=True,
            )
        return info

    def delete_db_instance(self, db_instance_id: str) -> None:
        release_container(f"localemu-rds-{db_instance_id}")
        return original_delete(self, db_instance_id)

    DockerDbManager.create_db_instance = create_db_instance
    DockerDbManager.delete_db_instance = delete_db_instance


def _attach_rds(info) -> None:
    db_id = getattr(info, "db_instance_id", None)
    container = getattr(info, "container_name", None)
    if not db_id or not container:
        return
    found = _find_rds(db_id)
    if found is None:
        LOG.debug("RDS %s: moto record not found", db_id)
        return
    account_id, region, db = found
    eni_id = f"eni-rds-{db_id}"
    from localemu.services.ec2.docker.address_index import get_address_index

    existing = get_address_index().get_eni(eni_id)
    vpc_id = (
        getattr(info, "vpc_id", None)
        or (existing.vpc_id if existing is not None else None)
        or _vpc_from_db(db)
    )
    if not vpc_id:
        return
    subnet_id = (
        (existing.subnet_id if existing is not None else None)
        or _subnet_from_db(db)
        or ""
    )
    sg_ids = [str(sg) for sg in (getattr(db, "vpc_security_group_ids", None) or []) if sg]
    if not sg_ids:
        sg_ids = _default_sg_ids(vpc_id, account_id, region)
    ip = _container_vpc_ip(container, vpc_id, getattr(info, "container_ip", None))
    if not ip:
        LOG.warning("RDS %s: no VPC IP to enforce", db_id)
        return
    _upsert_eni(
        eni_id=eni_id,
        vpc_id=vpc_id,
        subnet_id=subnet_id,
        ip=ip,
        sg_ids=sg_ids,
        instance_id=f"rds:{db_id}",
    )
    _remember(container, eni_id, account_id, region, sg_ids, "rds", vpc_id)
    _apply(container, sg_ids, account_id, region)
    _refresh_referencers(sg_ids, account_id, region)


def _remember(container, eni_id, account_id, region, sg_ids, kind, vpc_id="") -> None:
    wl = Workload(
        container=container,
        eni_id=eni_id,
        account_id=account_id,
        region=region,
        sg_ids=list(sg_ids),
        kind=kind,
        vpc_id=vpc_id or "",
    )
    with _lock:
        _workloads[container] = wl


def _apply(container: str, sg_ids: list[str], account_id: str, region: str) -> bool:
    try:
        from localemu.services.ec2.docker import sg_iptables
        from localemu.services.ec2.docker.vpc_routing import (
            _container_has_iptables,
            _sh_netns,
        )

        # Images that already have iptables (EC2, many ECS/RDS) stay in-container.
        # Lambda Amazon Linux has none — never ensure_iptables/apt (#369); program
        # the same SG_IN/SG_OUT script through the privileged alpine netns sidecar.
        if _container_has_iptables(container):
            ok = bool(
                sg_iptables.apply_sg_to_container(
                    container, sg_ids, account_id, region
                )
            )
        else:
            in_rules, out_rules = sg_iptables._collect_rules(
                sg_ids, account_id, region
            )
            script = sg_iptables._build_apply_script(in_rules, out_rules)
            # _sh_netns → False when the sidecar raises (non-zero exit / docker error).
            ok = _sh_netns(container, script)
            if ok:
                LOG.debug(
                    "Container %s: applied SG via netns sidecar (%d in, %d out)",
                    container,
                    len(in_rules),
                    len(out_rules),
                )
            else:
                LOG.warning(
                    "SG netns sidecar failed for %s (%s)",
                    container,
                    sg_ids,
                )
    except Exception:
        LOG.warning("SG apply failed for %s (%s)", container, sg_ids, exc_info=True)
        return False
    with _lock:
        wl = _workloads.get(container)
    if ok and wl is not None and wl.kind == "lambda":
        _allow_lambda_control_plane(container)
    if ok and wl is not None and wl.kind == "ecs":
        _allow_ecs_task_plane(container, wl)
    return ok


def _allow_lambda_control_plane(container: str) -> None:
    """Permit LocalEmu → runtime API; AWS does not put that path through the ENI SG."""
    try:
        from localemu.services.ec2.docker.vpc_endpoint import _localemu_gateway
        from localemu.services.ec2.docker.vpc_routing import _sh_netns

        parts = [
            "iptables -C SG_IN -s 127.0.0.0/8 -j ACCEPT 2>/dev/null || "
            "iptables -I SG_IN 1 -s 127.0.0.0/8 -j ACCEPT",
        ]
        gw_ip, _gw_net = _localemu_gateway()
        if gw_ip:
            parts.append(
                f"iptables -C SG_IN -s {gw_ip}/32 -j ACCEPT 2>/dev/null || "
                f"iptables -I SG_IN 1 -s {gw_ip}/32 -j ACCEPT"
            )
        # Bridge gateway used when the compose network is not the self-IP path.
        parts.append(
            "iptables -C SG_IN -s 172.17.0.1/32 -j ACCEPT 2>/dev/null || "
            "iptables -I SG_IN 1 -s 172.17.0.1/32 -j ACCEPT"
        )
        if not _sh_netns(container, "; ".join(parts)):
            LOG.warning(
                "Lambda control-plane SG_IN allow failed for %s",
                container,
            )
    except Exception:
        LOG.warning(
            "Lambda control-plane SG_IN allow failed for %s",
            container,
            exc_info=True,
        )


def _allow_ecs_task_plane(container: str, wl: Workload) -> None:
    """Exempt ECS task-creds link-local and stand-in AWS_ENDPOINT_URL (#686).

    On AWS the credentials endpoint is link-local and not subject to security
    groups. Locally filter OUTPUT sees the post-DNAT destination (LocalEmu
    creds port), so that /32:port is accepted too.

    Injected ``AWS_ENDPOINT_URL`` traffic is accepted only when the VPC has a
    VPC endpoint and the task SG would allow HTTPS egress that would reach an
    interface ENI (VPC CIDR :443) or a gateway prefix list — same shape as the
    real path through private endpoints.
    """
    try:
        from localemu.services.ec2.docker.vpc_endpoint import _localemu_gateway
        from localemu.services.ec2.docker.vpc_routing import _sh_netns

        parts = [
            # Link-local task metadata / credentials (pre-DNAT dest).
            "iptables -C SG_OUT -d 169.254.170.2/32 -j ACCEPT 2>/dev/null || "
            "iptables -I SG_OUT 1 -d 169.254.170.2/32 -j ACCEPT",
        ]
        gw_ip, _gw_net = _localemu_gateway()
        if gw_ip:
            creds_port = _ecs_creds_port()
            if creds_port:
                # Post-DNAT: 169.254.170.2:80 → LocalEmu compose IP:creds_port.
                parts.append(
                    f"iptables -C SG_OUT -d {gw_ip}/32 -p tcp "
                    f"--dport {creds_port} -j ACCEPT 2>/dev/null || "
                    f"iptables -I SG_OUT 1 -d {gw_ip}/32 -p tcp "
                    f"--dport {creds_port} -j ACCEPT"
                )
            if _endpoint_url_sg_stand_in_allowed(
                wl.vpc_id, wl.sg_ids, wl.account_id, wl.region
            ):
                gw_port = _gateway_listen_port()
                if gw_port:
                    parts.append(
                        f"iptables -C SG_OUT -d {gw_ip}/32 -p tcp "
                        f"--dport {gw_port} -j ACCEPT 2>/dev/null || "
                        f"iptables -I SG_OUT 1 -d {gw_ip}/32 -p tcp "
                        f"--dport {gw_port} -j ACCEPT"
                    )
        if not _sh_netns(container, "; ".join(parts)):
            LOG.warning("ECS task-plane SG_OUT allow failed for %s", container)
    except Exception:
        LOG.warning(
            "ECS task-plane SG_OUT allow failed for %s",
            container,
            exc_info=True,
        )


def _ecs_creds_port() -> int | None:
    try:
        from localemu.services.ecs.docker.task_credentials import (
            get_task_credentials_server,
        )

        return int(get_task_credentials_server().port)
    except Exception:
        LOG.debug("ECS creds port lookup failed", exc_info=True)
        return None


def _gateway_listen_port() -> int | None:
    try:
        from localemu import config as _le_config

        return int(_le_config.GATEWAY_LISTEN[0].port)
    except Exception:
        LOG.debug("gateway listen port lookup failed", exc_info=True)
        return None


def _endpoint_url_sg_stand_in_allowed(
    vpc_id: str, sg_ids: list[str], account_id: str, region: str
) -> bool:
    """Allow AWS_ENDPOINT_URL when a VPCE exists and SG would allow HTTPS to it."""
    if not vpc_id or not sg_ids:
        return False
    if not _vpc_has_endpoints(vpc_id, account_id, region):
        return False
    return _sg_allows_https_egress(sg_ids, account_id, region)


def _vpc_has_endpoints(vpc_id: str, account_id: str, region: str) -> bool:
    try:
        import moto.backends as moto_backends

        backend = moto_backends.get_backend("ec2")[account_id][region]
        for ep in (getattr(backend, "vpc_end_points", None) or {}).values():
            if getattr(ep, "vpc_id", None) == vpc_id:
                return True
    except Exception:
        LOG.debug("VPC endpoint lookup failed for %s", vpc_id, exc_info=True)
    return False


def _sg_allows_https_egress(
    sg_ids: list[str], account_id: str, region: str
) -> bool:
    """True when compiled SG_OUT would ACCEPT tcp/443 or any-protocol egress."""
    try:
        from localemu.services.ec2.docker import sg_iptables

        _in_rules, out_rules = sg_iptables._collect_rules(sg_ids, account_id, region)
    except Exception:
        LOG.debug("SG egress inspect failed", exc_info=True)
        return False
    for rule in out_rules:
        if "-j ACCEPT" not in rule:
            continue
        # Any-protocol ACCEPT (no ``-p``) covers ENI HTTPS on AWS.
        if " -p " not in rule:
            return True
        if " -p all " in rule:
            return True
        if " -p tcp " not in rule and " -p 6 " not in rule:
            continue
        if _tcp_rule_covers_https(rule):
            return True
    return False


def _tcp_rule_covers_https(rule: str) -> bool:
    """Return True when an iptables tcp ACCEPT rule covers destination port 443."""
    marker = "--dport "
    idx = rule.find(marker)
    if idx < 0:
        # ``-p tcp`` without dport = all TCP ports.
        return True
    token = rule[idx + len(marker) :].split(None, 1)[0]
    if ":" in token:
        left, right = token.split(":", 1)
        try:
            return int(left) <= 443 <= int(right)
        except ValueError:
            return False
    try:
        return int(token) == 443
    except ValueError:
        return False


def _refresh_referencers(sg_ids: list[str], account_id: str, region: str) -> None:
    if not sg_ids:
        return
    try:
        from localemu.services.ec2.docker.sg_reapply import reapply_sgs_referencing

        reapply_sgs_referencing(sg_ids, account_id, region)
    except Exception:
        LOG.debug("SG referencer refresh failed", exc_info=True)


def _reapply_prefix_list(prefix_list_id: str, account_id: str, region: str) -> None:
    import moto.backends as moto_backends

    from localemu.services.ec2.docker.sg_reapply import reapply_sg_for_sg_id

    backend = moto_backends.get_backend("ec2")[account_id][region]
    for sg in backend.describe_security_groups():
        rules = list(getattr(sg, "ingress_rules", None) or [])
        rules.extend(getattr(sg, "egress_rules", None) or [])
        if any(_prefix_id(rule) == prefix_list_id for rule in rules):
            reapply_sg_for_sg_id(sg.id, account_id, region)


def _expand_prefix_lists(sg_rules, account_id: str, region: str) -> list:
    expanded = []
    for rule in sg_rules:
        prefix_id = _prefix_id(rule)
        if not prefix_id or _rule_has_cidr(rule) or _rule_has_group(rule):
            expanded.append(rule)
            if prefix_id:
                expanded.extend(
                    _cidr_rules(rule, _prefix_cidrs(prefix_id, account_id, region))
                )
            continue
        cidrs = _prefix_cidrs(prefix_id, account_id, region)
        if cidrs:
            expanded.extend(_cidr_rules(rule, cidrs))
        else:
            expanded.append(
                _copy_rule(rule, ip_range={}, source_group={"GroupId": "sg-empty-prefix"})
            )
    return expanded


def _cidr_rules(rule, cidrs: list[str]) -> list:
    return [
        _copy_rule(rule, ip_range={"CidrIp": cidr}, ip_ranges=[], source_group={}, source_groups=[])
        for cidr in cidrs
    ]


def _copy_rule(rule, **overrides):
    ns = SimpleNamespace(
        ip_protocol=getattr(rule, "ip_protocol", "-1"),
        from_port=getattr(rule, "from_port", None),
        to_port=getattr(rule, "to_port", None),
        ip_ranges=list(getattr(rule, "ip_ranges", None) or []),
        ip_range=dict(getattr(rule, "ip_range", None) or {}),
        source_groups=list(getattr(rule, "source_groups", None) or []),
        source_group=dict(getattr(rule, "source_group", None) or {}),
    )
    for key, value in overrides.items():
        setattr(ns, key, value)
    return ns


def _prefix_id(rule) -> str | None:
    raw = getattr(rule, "prefix_list_id", None)
    if isinstance(raw, dict):
        raw = raw.get("PrefixListId")
    if isinstance(raw, str) and raw:
        return raw
    return None


def _rule_has_cidr(rule) -> bool:
    ip_range = getattr(rule, "ip_range", None) or {}
    if isinstance(ip_range, dict) and (ip_range.get("CidrIp") or ip_range.get("CidrIpv6")):
        return True
    for legacy in getattr(rule, "ip_ranges", None) or []:
        if isinstance(legacy, str) and legacy:
            return True
        if isinstance(legacy, dict) and (legacy.get("CidrIp") or legacy.get("CidrIpv6")):
            return True
    return False


def _rule_has_group(rule) -> bool:
    single = getattr(rule, "source_group", None) or {}
    if isinstance(single, dict) and single.get("GroupId"):
        return True
    for ref in getattr(rule, "source_groups", None) or []:
        gid = ref.get("GroupId") if isinstance(ref, dict) else getattr(ref, "group_id", None)
        if gid:
            return True
    return False


def _prefix_cidrs(prefix_list_id: str, account_id: str, region: str) -> list[str]:
    import moto.backends as moto_backends

    backend = moto_backends.get_backend("ec2")[account_id][region]
    listed = getattr(backend, "managed_prefix_lists", {}).get(prefix_list_id)
    if listed is None:
        return []
    bucket = getattr(listed, "entries", None) or {}
    version = getattr(listed, "version", None)
    chosen = bucket.get(version)
    if chosen is None and bucket:
        numeric = [key for key in bucket if isinstance(key, int)]
        chosen = bucket[max(numeric)] if numeric else next(iter(bucket.values()))
    cidrs = []
    for item in chosen or []:
        cidr = item.get("Cidr") if isinstance(item, dict) else None
        if cidr and ":" not in cidr:
            cidrs.append(cidr)
    return cidrs


def _upsert_eni(eni_id, vpc_id, subnet_id, ip, sg_ids, instance_id) -> None:
    from localemu.services.ec2.docker.address_index import get_address_index

    index = get_address_index()
    if index.get_eni(eni_id) is None:
        index.register_eni(
            eni_id=eni_id,
            vpc_id=vpc_id,
            subnet_id=subnet_id,
            primary_ip=ip,
            sg_ids=sg_ids,
            instance_id=instance_id,
            iface_name="eth1",
        )
        return
    index.update_sgs(eni_id, sg_ids)


def _eni_id(kind: str, docker_name: str) -> str:
    safe = docker_name.removeprefix("localemu-")
    return f"eni-{kind}-{safe}"


def _container_vpc_ip(container: str, vpc_id: str, fallback: str | None) -> str | None:
    from localemu.utils.docker_utils import DOCKER_CLIENT

    network = f"localemu-vpc-{vpc_id}"
    try:
        ip = DOCKER_CLIENT.get_container_ipv4_for_network(container, network)
    except Exception:
        ip = None
    if ip:
        return ip
    if fallback and fallback not in ("localhost", "127.0.0.1"):
        return fallback
    return None


def _vpc_for_subnet(subnet_id: str, account_id: str, region: str) -> str | None:
    try:
        from localemu.services.ec2.docker.vpc_network import get_vpc_network_manager

        vpc_id = get_vpc_network_manager().get_vpc_id_for_subnet(
            subnet_id, account_id, region
        )
        if vpc_id:
            return vpc_id
    except Exception:
        LOG.debug("VPC lookup via network manager failed", exc_info=True)
    try:
        import moto.backends as moto_backends

        backend = moto_backends.get_backend("ec2")[account_id][region]
        subnet = backend.get_subnet(subnet_id)
        return getattr(subnet, "vpc_id", None)
    except Exception:
        LOG.debug("VPC lookup via moto failed for %s", subnet_id, exc_info=True)
        return None


def _default_sg_ids(vpc_id: str, account_id: str, region: str) -> list[str]:
    try:
        import moto.backends as moto_backends

        backend = moto_backends.get_backend("ec2")[account_id][region]
        sg = backend.get_default_security_group(vpc_id)
        sg_id = getattr(sg, "id", None)
        return [sg_id] if sg_id else []
    except Exception:
        LOG.debug("default SG lookup failed for %s", vpc_id, exc_info=True)
        return []


def _find_rds(db_id: str):
    from moto.rds.models import rds_backends

    for account, regions in rds_backends.items():
        for region, backend in regions.items():
            db = backend.databases.get(db_id)
            if db is not None:
                return str(account), str(region), db
    return None


def _vpc_from_db(db) -> str | None:
    group = getattr(db, "db_subnet_group", None)
    vpc_id = getattr(group, "vpc_id", None)
    if isinstance(vpc_id, str):
        return vpc_id
    return None


def _subnet_from_db(db) -> str | None:
    group = getattr(db, "db_subnet_group", None)
    subnets = getattr(group, "_subnets", None) or []
    if not subnets:
        return None
    return getattr(subnets[0], "id", None)
