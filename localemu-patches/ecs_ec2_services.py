"""EC2-backed ECS services (#207).

Container instances come from an Auto Scaling group tagged ``ecs:cluster``,
an EC2 instance tagged the same way or with ``ECS_CLUSTER=<name>`` in user
data, or ``RegisterContainerInstance``. The scheduler keeps ``desiredCount``
(replace a dead task, scale, roll a new task definition).

Bridge-mode ``loadBalancers`` register the task's dynamic host port on the
container instance. Moto stores one target per instance id, so the ports
live on the ELBv2 router that ``DescribeTargetHealth`` reads. Those ports
are published on the Docker host, not inside the EC2 container network
namespace — target health and the loopback NLB forwarder dial
``host.docker.internal``. ``ECS_NLB_FORWARD=0`` skips the loopback socket.

That forwarder binds ``127.0.0.1:<listener port>`` inside LocalEmu only,
next to the VPC-scoped NLB listener from #203. The #203 listener resolves an
``i-*`` target to the EC2 container address, where a bridge host port does not
exist, so it cannot carry this traffic (#247). Do not point the forwarder at
``0.0.0.0``: that would shadow the real listener bind.

``deploymentController: CODE_DEPLOY`` services start their initial (blue)
tasks like any other service. ``CreateDeployment`` with an ECS AppSpec then
launches the new task definition onto the idle target group, swaps the
listener with ``ModifyListener``, and stops the old tasks.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import socket
import threading
import time
from dataclasses import dataclass, field

import moto.backends as moto_backends

LOG = logging.getLogger(__name__)

_services: dict[str, "_Svc"] = {}
_services_lock = threading.Lock()
_proxies: dict[int, "_TcpProxy"] = {}
_proxy_lock = threading.Lock()
_stop = threading.Event()
_started = False
_host_cache = ""


class _Ctx:
    def __init__(self, account_id: str, region: str) -> None:
        self.account_id = account_id
        self.region = region


@dataclass
class _Lb:
    tg_arn: str
    container_name: str
    container_port: int


@dataclass
class _Reg:
    tg_arn: str
    instance_id: str
    port: int


@dataclass
class _Svc:
    account_id: str
    region: str
    cluster_short: str
    cluster_label: str
    service_arn: str
    service_name: str
    task_def_arn: str
    desired: int
    launch_type: str
    network_configuration: dict | None
    load_balancers: list[_Lb]
    controller: str
    # task_def_arn is what the running tasks use. A roll that could not start
    # replacements keeps it and waits in pending_td until a retry succeeds.
    pending_td: str = ""
    next_try: float = 0.0
    fails: int = 0
    tasks: dict[str, list[_Reg]] = field(default_factory=dict)
    busy: threading.Lock = field(default_factory=threading.Lock)


def install() -> None:
    global _started
    _patch_codedeploy()
    if _started:
        return
    _started = True
    threading.Thread(target=_loop, name="ecs-ec2-reconcile", daemon=True).start()
    LOG.info("ECS EC2 scheduler started (bridge dial host %s)", _docker_host())


def reset_state() -> None:
    with _services_lock:
        _services.clear()
    with _proxy_lock:
        for proxy in list(_proxies.values()):
            proxy.close()
        _proxies.clear()


def on_create_service(context: object, request: dict, service_data: dict) -> None:
    svc = _build(context, request, service_data)
    with _services_lock:
        _services[svc.service_arn] = svc
    svc.busy.acquire()
    try:
        _ensure_capacity(svc, context)
        _reconcile_body(svc)
        _sync_counts(svc, service_data)
        _remember(svc)
        LOG.info(
            "ECS service %s controller=%s running %d/%d",
            svc.service_name,
            svc.controller,
            len(svc.tasks),
            svc.desired,
        )
    finally:
        svc.busy.release()


def on_update_service(context: object, request: dict, service_data: dict) -> None:
    svc = _find(service_data)
    if svc is None:
        on_create_service(context, request, service_data)
        return
    # CODE_DEPLOY services only change task definition through CreateDeployment.
    if svc.controller != "CODE_DEPLOY" and request.get("taskDefinition"):
        target = str(service_data.get("taskDefinition") or svc.task_def_arn)
    else:
        target = svc.pending_td or svc.task_def_arn
    desired = _as_int(service_data.get("desiredCount"), svc.desired)
    net = service_data.get("networkConfiguration")
    if isinstance(net, dict):
        svc.network_configuration = net or None
    launch = service_data.get("launchType")
    if isinstance(launch, str) and launch:
        svc.launch_type = launch
    lbs = _parse_lbs(request.get("loadBalancers")) or _parse_lbs(
        service_data.get("loadBalancers")
    )
    if lbs:
        svc.load_balancers = lbs
    svc.busy.acquire()
    try:
        svc.desired = desired
        svc.pending_td = "" if target == svc.task_def_arn else target
        svc.next_try = 0.0
        svc.fails = 0
        _ensure_capacity(svc, context)
        _reconcile_body(svc)
        if svc.pending_td:
            _roll(svc)
        _sync_counts(svc, service_data)
        _remember(svc)
    finally:
        svc.busy.release()


def on_delete_service(cluster: str, service_name: str) -> None:
    short = cluster.split("/")[-1] if cluster else ""
    with _services_lock:
        chosen = [
            svc
            for svc in _services.values()
            if service_name
            and (svc.service_name == service_name or service_name in svc.service_arn)
            and (
                not short
                or svc.cluster_short == short
                or short in svc.cluster_label
            )
        ]
    for svc in chosen:
        svc.busy.acquire()
        try:
            for arn in list(svc.tasks):
                _forget(svc, arn)
            _remember_clear(svc)
        finally:
            svc.busy.release()
        with _services_lock:
            _services.pop(svc.service_arn, None)


def _loop() -> None:
    while not _stop.is_set():
        try:
            with _services_lock:
                snapshot = list(_services.values())
            for svc in snapshot:
                if not svc.busy.acquire(blocking=False):
                    continue
                try:
                    _ensure_capacity(svc, None)
                    _reconcile_body(svc)
                    if svc.pending_td and time.monotonic() >= svc.next_try:
                        _roll(svc)
                    _sync_counts(svc, None)
                    _remember(svc)
                except Exception:
                    LOG.warning(
                        "ECS reconcile failed for %s", svc.service_name, exc_info=True
                    )
                finally:
                    svc.busy.release()
        except Exception:
            LOG.debug("ECS reconcile loop error", exc_info=True)
        _stop.wait(2.0)


def _reconcile_body(svc: _Svc) -> None:
    for arn in list(svc.tasks):
        if not _is_running(arn):
            LOG.info("ECS service %s replacing stopped task %s", svc.service_name, arn)
            _forget(svc, arn)
    while len(svc.tasks) > svc.desired:
        arn = next(reversed(list(svc.tasks)))
        _forget(svc, arn)
    if len(svc.tasks) >= svc.desired or time.monotonic() < svc.next_try:
        return
    guard = 0
    while len(svc.tasks) < svc.desired and guard < svc.desired + 1:
        guard += 1
        if _launch(svc, 1, None) <= 0:
            _backoff(svc, "replacement task did not start")
            return
    svc.fails = 0


def _backoff(svc: _Svc, why: str) -> None:
    svc.fails += 1
    delay = min(2 ** svc.fails, 30)
    svc.next_try = time.monotonic() + delay
    LOG.warning("ECS service %s: %s; retry in %ds", svc.service_name, why, delay)


def _roll(svc: _Svc) -> bool:
    """Start desiredCount tasks on pending_td, then stop the old ones.

    All or nothing: if any replacement fails to start, stop the new tasks,
    keep the old ones and the old task definition, and retry later.
    """
    target = svc.pending_td
    old = list(svc.tasks)
    added = _launch(svc, svc.desired, None, task_def=target)
    if added < svc.desired:
        for arn in list(svc.tasks):
            if arn not in old:
                _forget(svc, arn)
        _backoff(svc, f"roll to {target} started {added}/{svc.desired} tasks, kept old tasks")
        return False
    for arn in old:
        _forget(svc, arn)
    svc.task_def_arn = target
    svc.pending_td = ""
    svc.fails = 0
    svc.next_try = 0.0
    LOG.info(
        "ECS service %s rolled to %s (%d tasks)",
        svc.service_name,
        target,
        len(svc.tasks),
    )
    return True


def _launch(
    svc: _Svc, count: int, lbs: list[_Lb] | None, task_def: str | None = None
) -> int:
    if count <= 0:
        return 0
    from localemu.services.ecs.provider import _run_service_tasks

    use = svc.load_balancers if lbs is None else lbs
    try:
        arns = _run_service_tasks(
            _Ctx(svc.account_id, svc.region),
            svc.cluster_label,
            task_def or svc.task_def_arn,
            count,
            svc.launch_type,
            network_configuration=svc.network_configuration,
            group=f"service:{svc.service_name}",
        )
    except Exception:
        LOG.warning("ECS service %s RunTask failed", svc.service_name, exc_info=True)
        return 0
    added = 0
    for arn in arns:
        if not _is_running(arn):
            LOG.warning("ECS service task %s did not reach RUNNING", arn)
            _stop_quiet(svc, arn)
            continue
        svc.tasks[arn] = _register_task(svc, arn, use)
        added += 1
    return added


def _register_task(svc: _Svc, task_arn: str, lbs: list[_Lb]) -> list[_Reg]:
    if not lbs:
        return []
    info = _task_info(task_arn)
    if info is None:
        return []
    instance_id = _task_instance_id(svc, task_arn)
    if not instance_id:
        # awsvpc / Fargate: real ECS registers the task's ENI address into an ip-type target group.
        ip = getattr(info, "private_ipv4", None)
        if not ip:
            LOG.warning("ECS task %s has no container instance or address; not registered", task_arn)
            return []
        ip_regs: list[_Reg] = []
        names = {str(getattr(c, "container_name", "") or "") for c in getattr(info, "containers", []) or []}
        for lb in lbs:
            if lb.container_name in names:
                _register_target(svc, lb.tg_arn, str(ip), lb.container_port, direct=True)
                ip_regs.append(_Reg(lb.tg_arn, str(ip), lb.container_port))
                LOG.info("Registered %s:%s into %s for task %s", ip, lb.container_port, lb.tg_arn, task_arn.split("/")[-1])
        return ip_regs
    regs: list[_Reg] = []
    containers = getattr(info, "containers", []) or []
    for container in containers:
        if getattr(container, "status", "") != "RUNNING":
            continue
        name = str(getattr(container, "container_name", "") or "")
        ports = getattr(container, "host_ports", None) or {}
        if not isinstance(ports, dict):
            continue
        for lb in lbs:
            if lb.container_name != name:
                continue
            host_port = ports.get(lb.container_port)
            if not isinstance(host_port, int):
                continue
            _register_target(svc, lb.tg_arn, instance_id, host_port)
            regs.append(_Reg(lb.tg_arn, instance_id, host_port))
            LOG.info(
                "Registered %s:%s into %s for task %s",
                instance_id,
                host_port,
                lb.tg_arn,
                task_arn.split("/")[-1],
            )
    if lbs and not regs:
        LOG.warning("ECS task %s is running but has no bridge host port to register", task_arn)
    return regs


def _forget(svc: _Svc, task_arn: str) -> None:
    regs = svc.tasks.pop(task_arn, [])
    for reg in regs:
        _deregister(svc, reg)
    _stop_quiet(svc, task_arn)


def _stop_quiet(svc: _Svc, task_arn: str) -> None:
    mgr = _mgr()
    if mgr is not None:
        try:
            mgr.stop_task(task_arn)
        except Exception:
            LOG.debug("docker stop %s failed", task_arn, exc_info=True)
    try:
        _ecs(svc.account_id, svc.region).stop_task(
            svc.cluster_short,
            task_arn,
            "Essential container in task exited",
        )
    except Exception:
        LOG.debug("moto stop %s failed", task_arn, exc_info=True)


def _is_running(task_arn: str) -> bool:
    info = _task_info(task_arn)
    if info is None:
        return False
    return str(getattr(info, "status", "") or "") == "RUNNING"


def _task_info(task_arn: str) -> object | None:
    mgr = _mgr()
    if mgr is None:
        return None
    return mgr.get_task_status(task_arn)


def _mgr() -> object | None:
    from localemu.services.ecs.provider import _init_task_manager

    return _init_task_manager()


def _ensure_capacity(svc: _Svc, context: object | None) -> None:
    _adopt(svc)
    if _has_instances(svc) or svc.launch_type.upper() == "FARGATE":
        return
    from localemu.services.ecs.provider import _ensure_synthetic_instance

    ctx = context if context is not None else _Ctx(svc.account_id, svc.region)
    _ensure_synthetic_instance(ctx, svc.cluster_short, launch_type=svc.launch_type)


def _has_instances(svc: _Svc) -> bool:
    ecs = _ecs(svc.account_id, svc.region)
    cis = ecs.container_instances.get(svc.cluster_short) or {}
    return bool(cis)


def _adopt(svc: _Svc) -> None:
    ecs = _ecs(svc.account_id, svc.region)
    cis = ecs.container_instances.get(svc.cluster_short)
    if not isinstance(cis, dict):
        cis = {}
        ecs.container_instances[svc.cluster_short] = cis
    known = {str(getattr(ci, "ec2_instance_id", "") or "") for ci in cis.values()}
    wanted: dict[str, str] = {}
    try:
        ec2 = moto_backends.get_backend("ec2")[svc.account_id][svc.region]
        for inst in ec2.all_instances():
            iid = str(getattr(inst, "id", "") or "")
            if not iid or _instance_state_name(inst) in ("terminated", "shutting-down"):
                continue
            if _instance_matches_cluster(inst, svc.cluster_short):
                wanted[iid] = "ec2-tag-or-userdata"
    except Exception:
        LOG.debug("EC2 adopt skipped for %s", svc.cluster_short, exc_info=True)
    try:
        asg = moto_backends.get_backend("autoscaling")[svc.account_id][svc.region]
        groups = getattr(asg, "autoscaling_groups", {}) or {}
        for group in groups.values():
            if not _asg_matches(group, svc.cluster_short):
                continue
            members = group.active_instances() if hasattr(group, "active_instances") else []
            for member in members:
                iid = str(getattr(member, "instance_id", "") or "")
                if iid:
                    wanted[iid] = f"asg:{getattr(group, 'name', '')}"
    except Exception:
        LOG.debug("ASG adopt skipped for %s", svc.cluster_short, exc_info=True)
    for iid, reason in wanted.items():
        if not iid or iid in known:
            continue
        try:
            ecs.register_container_instance(svc.cluster_short, iid)
            known.add(iid)
            LOG.info(
                "Registered container instance %s on %s (%s)",
                iid,
                svc.cluster_short,
                reason,
            )
        except Exception:
            LOG.warning(
                "Failed to register container instance %s on %s",
                iid,
                svc.cluster_short,
                exc_info=True,
            )


def _instance_state_name(inst: object) -> str:
    state = getattr(inst, "state", None)
    if isinstance(state, str):
        return state
    if isinstance(state, dict):
        return str(state.get("Name") or state.get("name") or "")
    name = getattr(state, "name", None)
    return str(name or "")


def _instance_matches_cluster(inst: object, cluster: str) -> bool:
    tags = _tag_list_to_map(_safe_tags(inst))
    if tags.get("ecs:cluster") == cluster:
        return True
    text = _user_data_text(inst)
    return f"ECS_CLUSTER={cluster}" in text


def _asg_matches(group: object, cluster: str) -> bool:
    raw = getattr(group, "tags", None) or []
    tags = _tag_list_to_map(list(raw) if isinstance(raw, list) else [])
    return tags.get("ecs:cluster") == cluster


def _safe_tags(inst: object) -> list:
    getter = getattr(inst, "get_tags", None)
    if not callable(getter):
        return []
    try:
        raw = getter()
    except Exception:
        return []
    return raw if isinstance(raw, list) else []


def _tag_list_to_map(raw: list) -> dict[str, str]:
    out: dict[str, str] = {}
    for tag in raw:
        if not isinstance(tag, dict):
            continue
        key = str(tag.get("Key") or tag.get("key") or "")
        val = tag.get("Value")
        if val is None:
            val = tag.get("value")
        if key:
            out[key] = str(val or "")
    return out


def _user_data_text(inst: object) -> str:
    ud = getattr(inst, "user_data", None)
    if ud is None:
        return ""
    decode = getattr(ud, "decode", None)
    if callable(decode):
        try:
            return str(decode())
        except Exception:
            return str(ud)
    text = str(ud)
    try:
        return base64.b64decode(text, validate=True).decode("utf-8", "replace")
    except Exception:
        return text


def _task_instance_id(svc: _Svc, task_arn: str) -> str:
    ecs = _ecs(svc.account_id, svc.region)
    task = None
    bucket = ecs.tasks.get(svc.cluster_short) or {}
    if isinstance(bucket, dict):
        task = bucket.get(task_arn)
    if task is None:
        for candidate in ecs.tasks.values():
            if isinstance(candidate, dict) and task_arn in candidate:
                task = candidate[task_arn]
                break
    if task is None:
        return ""
    ci_arn = str(getattr(task, "container_instance_arn", "") or "")
    ci_id = ci_arn.split("/")[-1] if ci_arn else ""
    cis = ecs.container_instances.get(svc.cluster_short) or {}
    ci = cis.get(ci_id) if isinstance(cis, dict) else None
    if ci is None and isinstance(cis, dict):
        for item in cis.values():
            if str(getattr(item, "container_instance_arn", "") or "") == ci_arn:
                ci = item
                break
    if ci is None:
        return ""
    return str(getattr(ci, "ec2_instance_id", "") or "")


def _register_target(svc: _Svc, tg_arn: str, instance_id: str, port: int, direct: bool = False) -> None:
    try:
        from localemu.services.elbv2.listener_router import get_router
    except Exception:
        LOG.warning("ELBv2 router unavailable; target %s:%s not registered", instance_id, port)
        return
    _ensure_router_tg(svc.account_id, svc.region, tg_arn)
    router = get_router()
    router.add_targets(tg_arn, [{"Id": instance_id, "Port": port}])
    tg = router.target_groups.get(tg_arn)
    target = None
    if tg is not None:
        target = tg.targets.get(f"{instance_id}:{port}")
    if target is not None and not direct:
        # Bridge host ports are published on the Docker host. The EC2
        # container's VPC address is not listening on this port.
        target.host = _docker_host()
    try:
        _elbv2(svc.account_id, svc.region).register_targets(
            tg_arn, [{"Id": instance_id, "Port": port}]
        )
    except Exception:
        LOG.debug("moto register_targets %s:%s failed", instance_id, port, exc_info=True)
    _ensure_proxies_for_tg(svc.account_id, svc.region, tg_arn)


def _deregister(svc: _Svc, reg: _Reg) -> None:
    try:
        from localemu.services.elbv2.listener_router import get_router

        get_router().remove_targets(reg.tg_arn, [{"Id": reg.instance_id, "Port": reg.port}])
    except Exception:
        LOG.debug("router deregister failed", exc_info=True)
    still = False
    for regs in svc.tasks.values():
        for other in regs:
            if other.tg_arn == reg.tg_arn and other.instance_id == reg.instance_id:
                still = True
    if still:
        return
    try:
        _elbv2(svc.account_id, svc.region).deregister_targets(
            reg.tg_arn, [{"Id": reg.instance_id, "Port": reg.port}]
        )
    except Exception:
        LOG.debug("moto deregister_targets failed", exc_info=True)


def _ensure_router_tg(account_id: str, region: str, tg_arn: str) -> None:
    from localemu.services.elbv2.listener_router import TargetGroup, get_router

    router = get_router()
    if tg_arn in router.target_groups:
        return
    name = tg_arn
    protocol = "TCP"
    port = 80
    try:
        tg = _elbv2(account_id, region).target_groups.get(tg_arn)
    except Exception:
        tg = None
    if tg is not None:
        name = str(getattr(tg, "name", None) or getattr(tg, "target_group_name", None) or name)
        protocol = str(getattr(tg, "protocol", None) or protocol)
        raw_port = getattr(tg, "port", None)
        if isinstance(raw_port, int):
            port = raw_port
        elif isinstance(raw_port, str) and raw_port.isdigit():
            port = int(raw_port)
    router.register_target_group(
        TargetGroup(arn=tg_arn, name=name, protocol=protocol, port=port)
    )


def _ensure_proxies_for_tg(account_id: str, region: str, tg_arn: str) -> None:
    for lis in _each_listener(account_id, region):
        if _listener_tg(lis) == tg_arn:
            _ensure_proxy(account_id, region, str(getattr(lis, "arn", "") or ""))


def _ensure_proxy(account_id: str, region: str, listener_arn: str) -> None:
    if os.environ.get("ECS_NLB_FORWARD", "1").strip() == "0":
        return
    lis = _find_listener(account_id, region, listener_arn)
    if lis is None:
        return
    protocol = str(getattr(lis, "protocol", "") or "").upper()
    if protocol != "TCP":
        return
    raw_port = getattr(lis, "port", None)
    port = int(raw_port) if isinstance(raw_port, int) or (isinstance(raw_port, str) and raw_port.isdigit()) else 0
    if port <= 0:
        return
    with _proxy_lock:
        existing = _proxies.get(port)
        if existing is not None:
            existing.listener_arn = listener_arn
            existing.account_id = account_id
            existing.region = region
            return
        proxy = _TcpProxy(port, listener_arn, account_id, region)
        if proxy.ok:
            _proxies[port] = proxy


def _each_listener(account_id: str, region: str) -> list:
    try:
        elbv2 = _elbv2(account_id, region)
    except Exception:
        return []
    found = []
    for lb in getattr(elbv2, "load_balancers", {}).values():
        listeners = getattr(lb, "listeners", {}) or {}
        if isinstance(listeners, dict):
            found.extend(listeners.values())
    return found


def _find_listener(account_id: str, region: str, listener_arn: str) -> object | None:
    for lis in _each_listener(account_id, region):
        if str(getattr(lis, "arn", "") or "") == listener_arn:
            return lis
    return None


def _listener_tg(lis: object) -> str:
    actions = getattr(lis, "default_actions", None) or []
    if not actions:
        return ""
    action = actions[0]
    data = getattr(action, "data", None)
    if isinstance(data, dict):
        arn = data.get("TargetGroupArn") or ""
        if arn:
            return str(arn)
    return str(getattr(action, "TargetGroupArn", "") or "")


class _TcpProxy:
    def __init__(self, port: int, listener_arn: str, account_id: str, region: str) -> None:
        self.port = port
        self.listener_arn = listener_arn
        self.account_id = account_id
        self.region = region
        self.ok = False
        self._sock: socket.socket | None = None
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind(("127.0.0.1", port))
            sock.listen(32)
            sock.settimeout(1.0)
        except Exception as exc:
            LOG.warning("ECS NLB forwarder could not bind 127.0.0.1:%s: %s", port, exc)
            sock.close()
            return
        self._sock = sock
        self.ok = True
        threading.Thread(
            target=self._accept, name=f"ecs-nlb-{port}", daemon=True
        ).start()
        LOG.info(
            "ECS NLB forwarder on 127.0.0.1:%s for listener %s",
            port,
            listener_arn,
        )

    def close(self) -> None:
        sock = self._sock
        self._sock = None
        self.ok = False
        if sock is not None:
            try:
                sock.close()
            except Exception:
                pass

    def _accept(self) -> None:
        while self._sock is not None:
            try:
                conn, _addr = self._sock.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            threading.Thread(
                target=self._handle, args=(conn,), daemon=True
            ).start()

    def _handle(self, conn: socket.socket) -> None:
        upstream: socket.socket | None = None
        try:
            target = _pick_target(self.account_id, self.region, self.listener_arn)
            if target is None:
                return
            host = str(getattr(target, "host", "") or _docker_host())
            port = int(getattr(target, "port", 0) or 0)
            upstream = socket.create_connection((host, port), 3)
            from localemu.services.elbv2.listener_router import _pipe_sockets

            _pipe_sockets(conn, upstream)
        except Exception:
            LOG.debug("NLB forward failed", exc_info=True)
        finally:
            conn.close()
            if upstream is not None:
                upstream.close()


def _pick_target(account_id: str, region: str, listener_arn: str) -> object | None:
    lis = _find_listener(account_id, region, listener_arn)
    if lis is None:
        return None
    tg_arn = _listener_tg(lis)
    if not tg_arn:
        return None
    try:
        from localemu.services.elbv2.listener_router import _tcp_ping, get_router
    except Exception:
        return None
    tg = get_router().target_groups.get(tg_arn)
    if tg is None:
        return None
    host = _docker_host()
    with tg._lock:
        targets = list(tg.targets.values())
    for target in targets:
        if not getattr(target, "host", ""):
            target.host = host
        port = int(getattr(target, "port", 0) or 0)
        target.health = "healthy" if port and _tcp_ping(target.host, port, 0.4) else "unhealthy"
    return tg.pick_target()


def _docker_host() -> str:
    global _host_cache
    if _host_cache:
        return _host_cache
    override = os.environ.get("AWSBOX_ECS_PORT_HOST", "").strip()
    if override:
        _host_cache = override
        return _host_cache
    try:
        addr = socket.getaddrinfo("host.docker.internal", None, socket.AF_INET)[0][4][0]
        if isinstance(addr, str) and addr:
            _host_cache = addr
            return addr
    except Exception:
        LOG.debug("host.docker.internal unresolved", exc_info=True)
    try:
        with open("/proc/net/route", encoding="utf-8") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) >= 3 and parts[1] == "00000000" and parts[2] != "00000000":
                    raw = bytes.fromhex(parts[2])
                    _host_cache = ".".join(str(b) for b in reversed(raw))
                    return _host_cache
    except Exception:
        LOG.debug("default route lookup failed", exc_info=True)
    return "127.0.0.1"


def _sync_counts(svc: _Svc, service_data: dict | None) -> None:
    running = len(svc.tasks)
    pending = max(svc.desired - running, 0)
    try:
        obj = _ecs(svc.account_id, svc.region).services.get(
            f"{svc.cluster_short}:{svc.service_name}"
        )
    except Exception:
        obj = None
    if obj is not None:
        obj.running_count = running
        obj.pending_count = pending
        obj.task_definition = svc.task_def_arn
        deps = getattr(obj, "deployments", None) or []
        if deps and isinstance(deps[0], dict):
            deps[0]["runningCount"] = running
            deps[0]["pendingCount"] = pending
            deps[0]["desiredCount"] = svc.desired
            deps[0]["taskDefinition"] = svc.task_def_arn
    if service_data is not None:
        service_data["runningCount"] = running
        service_data["pendingCount"] = pending
        service_data["desiredCount"] = svc.desired
        service_data["taskDefinition"] = svc.task_def_arn
        service_data["status"] = "ACTIVE"


def _remember(svc: _Svc) -> None:
    from localemu.services.ecs.provider import _service_tasks, _service_tasks_lock

    with _service_tasks_lock:
        _service_tasks[svc.service_arn] = list(svc.tasks)


def _remember_clear(svc: _Svc) -> None:
    from localemu.services.ecs.provider import _service_tasks, _service_tasks_lock

    with _service_tasks_lock:
        _service_tasks.pop(svc.service_arn, None)


def _build(context: object, request: dict, service_data: dict) -> _Svc:
    account_id = str(getattr(context, "account_id", "") or "000000000000")
    region = str(getattr(context, "region", "") or "us-east-1")
    cluster_label = str(service_data.get("clusterArn") or request.get("cluster") or "default")
    cluster_short = cluster_label.split("/")[-1]
    service_arn = str(service_data.get("serviceArn") or "")
    service_name = str(service_data.get("serviceName") or request.get("serviceName") or "")
    task_def = str(service_data.get("taskDefinition") or request.get("taskDefinition") or "")
    desired = _as_int(service_data.get("desiredCount"), _as_int(request.get("desiredCount"), 0))
    launch = str(service_data.get("launchType") or request.get("launchType") or "EC2")
    net = service_data.get("networkConfiguration")
    if not isinstance(net, dict) or not net:
        net = request.get("networkConfiguration")
    network = net if isinstance(net, dict) and net else None
    lbs = _parse_lbs(request.get("loadBalancers")) or _parse_lbs(service_data.get("loadBalancers"))
    controller = _controller(request, service_data)
    return _Svc(
        account_id=account_id,
        region=region,
        cluster_short=cluster_short,
        cluster_label=cluster_label,
        service_arn=service_arn,
        service_name=service_name,
        task_def_arn=task_def,
        desired=desired,
        launch_type=launch,
        network_configuration=network,
        load_balancers=lbs,
        controller=controller,
    )


def _find(service_data: dict) -> _Svc | None:
    arn = str(service_data.get("serviceArn") or "")
    name = str(service_data.get("serviceName") or "")
    cluster = str(service_data.get("clusterArn") or "").split("/")[-1]
    with _services_lock:
        if arn and arn in _services:
            return _services[arn]
        for svc in _services.values():
            if svc.service_name == name and (not cluster or svc.cluster_short == cluster):
                return svc
    return None


def _controller(request: dict, service_data: dict) -> str:
    raw = request.get("deploymentController")
    if not isinstance(raw, dict):
        raw = service_data.get("deploymentController")
    if not isinstance(raw, dict):
        return "ECS"
    kind = raw.get("type") or raw.get("Type") or "ECS"
    return str(kind).upper()


def _parse_lbs(raw: object) -> list[_Lb]:
    if not isinstance(raw, list):
        return []
    out: list[_Lb] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        tg = item.get("targetGroupArn") or item.get("TargetGroupArn") or ""
        name = item.get("containerName") or item.get("ContainerName") or ""
        port = item.get("containerPort")
        if port is None:
            port = item.get("ContainerPort")
        if not tg or not name or port is None:
            continue
        if isinstance(port, bool) or not isinstance(port, (int, str)):
            continue
        if isinstance(port, str) and not port.isdigit():
            continue
        out.append(_Lb(str(tg), str(name), int(port)))
    return out


def _as_int(value: object, default: int) -> int:
    if isinstance(value, bool) or value is None:
        return default
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.lstrip("-").isdigit():
        return int(value)
    return default


def _ecs(account_id: str, region: str) -> object:
    return moto_backends.get_backend("ecs")[account_id][region]


def _elbv2(account_id: str, region: str) -> object:
    return moto_backends.get_backend("elbv2")[account_id][region]


def _patch_codedeploy() -> None:
    try:
        from moto.codedeploy.models import CodeDeployBackend
    except Exception:
        LOG.warning("CodeDeploy backend unavailable; blue/green disabled")
        return
    if getattr(CodeDeployBackend, "_awsbox_ecs_bg", False):
        return
    orig = CodeDeployBackend.create_deployment

    def wrapped(
        self: object,
        application_name: str,
        deployment_group_name: str,
        revision: object,
        deployment_config_name: str | None = None,
        description: str | None = None,
        ignore_application_stop_failures: bool | None = None,
        target_instances: object = None,
        auto_rollback_configuration: object = None,
        update_outdated_instances_only: object = None,
        file_exists_behavior: str | None = None,
        override_alarm_configuration: object = None,
    ) -> str:
        dep_id = orig(
            self,
            application_name,
            deployment_group_name,
            revision,
            deployment_config_name,
            description,
            ignore_application_stop_failures,
            target_instances,
            auto_rollback_configuration,
            update_outdated_instances_only,
            file_exists_behavior,
            override_alarm_configuration,
        )
        _finish_deployment(self, dep_id)
        return dep_id

    CodeDeployBackend.create_deployment = wrapped
    CodeDeployBackend._awsbox_ecs_bg = True


def _mark_succeeded(dep: object) -> None:
    dep.status = "Succeeded"
    overview = getattr(dep, "deployment_overview", None)
    if isinstance(overview, dict):
        overview["Succeeded"] = 1
        overview["Failed"] = 0
        overview["InProgress"] = 0


def _finish_deployment(backend: object, dep_id: str) -> None:
    deployments = getattr(backend, "deployments", {})
    dep = deployments.get(dep_id) if isinstance(deployments, dict) else None
    if dep is None:
        return
    group = getattr(dep, "deployment_group", None)
    ecs_services = getattr(group, "ecs_services", None) or []
    if not ecs_services:
        # Lambda/Server: control-plane Succeeded only (no alias weight shift).
        platform = str(
            getattr(getattr(dep, "application", None), "compute_platform", "") or ""
        ).upper()
        if platform == "LAMBDA":
            _mark_succeeded(dep)
        return
    try:
        _blue_green(backend, dep, ecs_services)
    except Exception as exc:
        LOG.warning("CodeDeploy ECS deployment %s failed: %s", dep_id, exc)
        dep.status = "Failed"
        dep.additional_deployment_status_info = str(exc)
        messages = getattr(dep, "deployment_status_messages", None)
        if isinstance(messages, list):
            messages.append(str(exc))
        overview = getattr(dep, "deployment_overview", None)
        if isinstance(overview, dict):
            overview["Failed"] = 1
            overview["Succeeded"] = 0
        return
    _mark_succeeded(dep)


def _blue_green(backend: object, dep: object, ecs_services: list) -> None:
    spec = ecs_services[0]
    if not isinstance(spec, dict):
        raise RuntimeError("ecsServices entry is not an object")
    service_name = str(spec.get("serviceName") or "")
    cluster_name = str(spec.get("clusterName") or "default")
    if not service_name:
        raise RuntimeError("ecsServices entry is missing serviceName")
    account_id = str(getattr(backend, "account_id", "") or "000000000000")
    region = str(getattr(backend, "region_name", "") or "us-east-1")
    appspec = _appspec(getattr(dep, "revision", None))
    td_arn, container_name, container_port = _appspec_target(appspec)
    if not _task_def_exists(_ecs(account_id, region), td_arn):
        raise RuntimeError(f"task definition not found: {td_arn}")
    listener_arn, dest_arn = _traffic_pair(
        account_id, region, getattr(getattr(dep, "deployment_group", None), "load_balancer_info", None)
    )
    svc = _runtime_for(account_id, region, cluster_name, service_name)
    if svc is None:
        raise RuntimeError(f"ECS service {service_name} not found on {cluster_name}")
    dest_lbs = [_Lb(dest_arn, container_name, container_port)]
    svc.busy.acquire()
    old = list(svc.tasks)
    previous_td = svc.task_def_arn
    try:
        if svc.desired < 1:
            svc.desired = 1
        svc.task_def_arn = td_arn
        _ensure_capacity(svc, None)
        added = _launch(svc, svc.desired, dest_lbs)
        if added < svc.desired:
            raise RuntimeError(f"started {added}/{svc.desired} tasks for blue/green")
        _swap_listener(account_id, region, listener_arn, dest_arn)
        for arn in old:
            _forget(svc, arn)
        svc.load_balancers = dest_lbs
        _sync_counts(svc, None)
        _remember(svc)
        LOG.info(
            "CodeDeploy swapped %s to %s (%d tasks)",
            listener_arn,
            dest_arn,
            len(svc.tasks),
        )
    except Exception:
        svc.task_def_arn = previous_td
        for arn in list(svc.tasks):
            if arn not in old:
                _forget(svc, arn)
        raise
    finally:
        svc.busy.release()


def _runtime_for(account_id: str, region: str, cluster_name: str, service_name: str) -> _Svc | None:
    short = cluster_name.split("/")[-1]
    with _services_lock:
        for svc in _services.values():
            if (
                svc.account_id == account_id
                and svc.region == region
                and svc.service_name == service_name
                and svc.cluster_short == short
            ):
                return svc
    ecs = _ecs(account_id, region)
    obj = ecs.services.get(f"{short}:{service_name}")
    if obj is None:
        return None
    lbs = _parse_lbs(getattr(obj, "load_balancers", None))
    controller = "ECS"
    raw = getattr(obj, "deployment_controller", None)
    if isinstance(raw, dict):
        controller = str(raw.get("type") or raw.get("Type") or "ECS").upper()
    net = getattr(obj, "network_configuration", None)
    svc = _Svc(
        account_id=account_id,
        region=region,
        cluster_short=short,
        cluster_label=str(getattr(obj, "cluster_arn", None) or short),
        service_arn=str(getattr(obj, "arn", None) or ""),
        service_name=service_name,
        task_def_arn=str(getattr(obj, "task_definition", None) or ""),
        desired=_as_int(getattr(obj, "desired_count", None), 1),
        launch_type=str(getattr(obj, "launch_type", None) or "EC2"),
        network_configuration=net if isinstance(net, dict) and net else None,
        load_balancers=lbs,
        controller=controller,
    )
    with _services_lock:
        if svc.service_arn:
            _services[svc.service_arn] = svc
    return svc


def _traffic_pair(account_id: str, region: str, info: object) -> tuple[str, str]:
    if not isinstance(info, dict):
        raise RuntimeError("deployment group has no loadBalancerInfo")
    pairs = info.get("targetGroupPairInfoList") or []
    if not isinstance(pairs, list) or not pairs or not isinstance(pairs[0], dict):
        raise RuntimeError("loadBalancerInfo has no target group pair")
    pair = pairs[0]
    names: list[str] = []
    for tg in pair.get("targetGroups") or []:
        if isinstance(tg, dict) and tg.get("name"):
            names.append(str(tg["name"]))
    route = pair.get("prodTrafficRoute") or {}
    listener_arns = route.get("listenerArns") if isinstance(route, dict) else None
    if not isinstance(listener_arns, list) or not listener_arns:
        raise RuntimeError("prodTrafficRoute has no listener")
    listener_arn = str(listener_arns[0])
    arn_by_name = {name: _tg_arn_by_name(account_id, region, name) for name in names}
    if any(not arn for arn in arn_by_name.values()):
        raise RuntimeError(f"target group name did not resolve: {names}")
    lis = _find_listener(account_id, region, listener_arn)
    if lis is None:
        raise RuntimeError(f"listener not found: {listener_arn}")
    current = _listener_tg(lis)
    dest = ""
    for arn in arn_by_name.values():
        if arn != current:
            dest = arn
            break
    if not dest:
        raise RuntimeError("no idle target group to deploy into")
    return listener_arn, dest


def _tg_arn_by_name(account_id: str, region: str, name: str) -> str:
    try:
        groups = _elbv2(account_id, region).target_groups
    except Exception:
        return ""
    for tg in groups.values():
        tg_name = str(getattr(tg, "name", None) or getattr(tg, "target_group_name", None) or "")
        if tg_name == name:
            return str(getattr(tg, "arn", "") or "")
    return ""


def _swap_listener(account_id: str, region: str, listener_arn: str, tg_arn: str) -> None:
    _elbv2(account_id, region).modify_listener(
        arn=listener_arn,
        port=None,
        protocol=None,
        ssl_policy=None,
        certificates=None,
        actions=[{"Type": "forward", "TargetGroupArn": tg_arn}],
    )
    _ensure_proxy(account_id, region, listener_arn)


def _appspec(revision: object) -> dict:
    rev = revision
    if isinstance(rev, str):
        try:
            rev = json.loads(rev)
        except json.JSONDecodeError as exc:
            raise RuntimeError("deployment revision is not JSON") from exc
    if not isinstance(rev, dict):
        raise RuntimeError("deployment revision is missing")
    content = rev.get("appSpecContent")
    if isinstance(content, dict) and "content" in content:
        raw = content.get("content")
        if isinstance(raw, str):
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise RuntimeError("AppSpec content is not JSON") from exc
            if isinstance(parsed, dict):
                return parsed
            raise RuntimeError("AppSpec content is not an object")
        if isinstance(raw, dict):
            return raw
    if "Resources" in rev:
        return rev
    raise RuntimeError("revision has no AppSpec content")


def _appspec_target(spec: dict) -> tuple[str, str, int]:
    resources = spec.get("Resources")
    if not isinstance(resources, list) or not resources or not isinstance(resources[0], dict):
        raise RuntimeError("AppSpec Resources is empty")
    target = resources[0].get("TargetService")
    if not isinstance(target, dict):
        raise RuntimeError("AppSpec TargetService is missing")
    props = target.get("Properties")
    if not isinstance(props, dict):
        raise RuntimeError("AppSpec TargetService.Properties is missing")
    td = props.get("TaskDefinition")
    lb = props.get("LoadBalancerInfo")
    if not isinstance(td, str) or not td:
        raise RuntimeError("AppSpec TaskDefinition is missing")
    if not isinstance(lb, dict):
        raise RuntimeError("AppSpec LoadBalancerInfo is missing")
    name = lb.get("ContainerName")
    port = lb.get("ContainerPort")
    if not isinstance(name, str) or not name:
        raise RuntimeError("AppSpec ContainerName is missing")
    if isinstance(port, bool) or not isinstance(port, (int, str)):
        raise RuntimeError("AppSpec ContainerPort is missing")
    if isinstance(port, str) and not port.isdigit():
        raise RuntimeError("AppSpec ContainerPort is missing")
    return td, name, int(port)


def _task_def_exists(ecs: object, ident: str) -> bool:
    try:
        found = ecs.describe_task_definition(ident)
    except Exception:
        return False
    return found is not None
