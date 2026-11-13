"""ECS provider with Docker-backed task execution.

awsbox patch (#201): pass ``secrets`` into the Docker task manager, and
surface honest RunTask/DescribeTasks status (STOPPED + stoppedReason) when
containers fail to start. Mounted over the LocalEmu image file.

Wraps Moto's ECS backend and adds Docker container management when
Docker is available. Creates a custom dispatch table that intercepts
specific ECS operations (RunTask, StopTask, etc.) while routing all
other operations directly to Moto.

Architecture (same pattern as EC2 Docker backend):
  1. Moto owns all state: clusters, task definitions, task records, ARNs.
  2. Docker provides execution: real containers from task definitions.
  3. Moto's RunTask requires a registered container instance (EC2 launch type).
     We register a synthetic instance lazily when the cluster has none,
     so an ASG or RegisterContainerInstance target is used first (#207).
"""

import logging
import os
import threading
import time

import moto.backends as moto_backends

from localemu.aws.api import RequestContext, ServiceRequest, ServiceResponse
from localemu.aws.skeleton import DispatchTable, Skeleton
from localemu.services.moto import _proxy_moto, call_moto, call_moto_with_request
from localemu.services.plugins import Service, ServiceLifecycleHook

LOG = logging.getLogger(__name__)

# Module-level task_manager singleton (double-checked locking)
_task_manager = None
_task_manager_lock = threading.Lock()

# Track synthetic EC2 instance IDs per cluster for cleanup
_synthetic_instances: dict[str, str] = {}


def _normalize_cluster_name(cluster: str) -> str:
    """Extract short cluster name from ARN or plain name (centralized normalization)."""
    if "/" in cluster:
        return cluster.split("/")[-1]
    return cluster


def _resolve_task_private_ipv4(task_info) -> str | None:
    """Best ENI address for an awsvpc task (task-level, else first container)."""
    ip = getattr(task_info, "private_ipv4", None)
    if ip:
        return ip
    for ci in getattr(task_info, "containers", []) or []:
        cip = getattr(ci, "private_ipv4", None)
        if cip:
            return cip
    # Live Docker probe when recovered tasks lack a stored address
    vpc_id = getattr(task_info, "vpc_id", None)
    if not vpc_id:
        return None
    network = f"localemu-vpc-{vpc_id}"
    try:
        from localemu.utils.docker_utils import DOCKER_CLIENT
    except Exception:
        return None
    for ci in getattr(task_info, "containers", []) or []:
        name = getattr(ci, "docker_name", None)
        if not name:
            continue
        try:
            found = DOCKER_CLIENT.get_container_ipv4_for_network(name, network)
        except TypeError:
            try:
                found = DOCKER_CLIENT.get_container_ipv4_for_network(
                    container_name_or_id=name,
                    container_network=network,
                )
            except Exception:
                found = None
        except Exception:
            found = None
        if found and found not in ("localhost", "127.0.0.1"):
            return str(found).split("/")[0]
    return None


def _set_attachment_detail(details: list, name: str, value: str) -> None:
    for d in details:
        if d.get("name") == name:
            d["value"] = value
            return
    details.append({"name": name, "value": value})


def _apply_awsvpc_eni_ip(task: dict, task_info, account_id: str, region: str) -> None:
    """Overwrite moto's random privateIPv4Address with the container VPC IP (#268)."""
    ip = _resolve_task_private_ipv4(task_info)
    if not ip:
        return

    for att in task.get("attachments") or []:
        if att.get("type") != "ElasticNetworkInterface":
            continue
        details = att.setdefault("details", [])
        _set_attachment_detail(details, "privateIPv4Address", ip)
        if getattr(task_info, "subnet_id", None):
            _set_attachment_detail(details, "subnetId", task_info.subnet_id)

    for mc in task.get("containers") or []:
        c_ip = ip
        for ci in getattr(task_info, "containers", []) or []:
            if ci.container_name == mc.get("name") and getattr(ci, "private_ipv4", None):
                c_ip = ci.private_ipv4
                break
        nis = mc.get("networkInterfaces")
        if not nis:
            mc["networkInterfaces"] = [{"privateIpv4Address": c_ip}]
        else:
            for ni in nis:
                ni["privateIpv4Address"] = c_ip

    _patch_moto_task_eni_ip(task.get("taskArn", ""), ip, account_id, region)


def _patch_moto_task_eni_ip(
    task_arn: str, ip: str, account_id: str, region: str,
) -> None:
    """Keep moto's Task.attachments / ENI in sync for later DescribeTasks."""
    if not task_arn or not ip:
        return
    try:
        backend = moto_backends.get_backend("ecs")[account_id][region]
    except Exception:
        return
    moto_task = None
    for cluster in getattr(backend, "clusters", {}).values():
        tasks = getattr(cluster, "tasks", None) or {}
        if task_arn in tasks:
            moto_task = tasks[task_arn]
            break
        # short id key
        short = task_arn.split("/")[-1]
        if short in tasks:
            moto_task = tasks[short]
            break
    if moto_task is None:
        return

    eni_id = None
    for att in getattr(moto_task, "attachments", None) or []:
        details = att.get("details") if isinstance(att, dict) else None
        if not details:
            continue
        for d in details:
            if d.get("name") == "privateIPv4Address":
                d["value"] = ip
            elif d.get("name") == "networkInterfaceId":
                eni_id = d.get("value")

    if not eni_id:
        return
    try:
        ec2 = moto_backends.get_backend("ec2")[account_id][region]
        eni = ec2.get_network_interface(eni_id) if hasattr(ec2, "get_network_interface") else None
        if eni is None:
            enis = getattr(ec2, "network_interfaces", None) or {}
            eni = enis.get(eni_id)
        if eni is None:
            return
        for attr in ("private_ip_address", "private_ip", "_private_ip"):
            if hasattr(eni, attr):
                try:
                    setattr(eni, attr, ip)
                except Exception:
                    pass
    except Exception:
        LOG.debug("moto ENI IP patch failed for %s", eni_id, exc_info=True)


def _init_task_manager():
    """Initialize the Docker Task Manager.

    Docker backend is enabled by default when Docker is available.
    Set ECS_DOCKER_BACKEND=0 to explicitly disable it.
    """
    global _task_manager
    if _task_manager is not None:
        return _task_manager

    with _task_manager_lock:
        if _task_manager is not None:
            return _task_manager

        # Opt-out instead of opt-in - enabled by default when Docker is available
        if os.environ.get("ECS_DOCKER_BACKEND", "").strip() == "0":
            return None

        try:
            from localemu.services.ecs.docker.task_manager import DockerTaskManager
            from localemu.utils.docker_utils import DOCKER_CLIENT

            if DOCKER_CLIENT.has_docker():
                _task_manager = DockerTaskManager()
                LOG.info("ECS Docker backend enabled (set ECS_DOCKER_BACKEND=0 to disable).")
            else:
                LOG.debug("Docker not available, ECS Docker backend disabled.")
        except Exception as e:
            LOG.warning("Failed to initialize ECS Docker backend: %s", e)

        return _task_manager


def _get_ecs_backend(context: RequestContext):
    """Return the Moto EC2ContainerServiceBackend for the request's account/region.

    Moto's BackendDict is two-level: ``backend[account_id][region]``.
    """
    return moto_backends.get_backend("ecs")[context.account_id][context.region]


def _ensure_synthetic_instance(context: RequestContext, cluster_name: str, launch_type: str = "EC2") -> None:
    """Ensure the cluster has a registered container instance for Moto's RunTask.

    Moto's ``run_task`` raises ``Exception("No instances found in cluster …")``
    when there are no registered container instances.  Since the Docker backend
    runs containers directly via Docker, we create a lightweight synthetic EC2
    instance and register it as a container instance.

    Moto's ``register_container_instance`` validates the ``ec2_instance_id``
    against the EC2 backend, so we must create a real Moto EC2 instance first.

    The call is idempotent - if the cluster already has instances, this is a
    no-op.

    For FARGATE launch type, skip synthetic instance creation since
    Fargate tasks don't need registered container instances.
    """
    # FARGATE tasks don't need container instances
    if launch_type and launch_type.upper() == "FARGATE":
        return

    try:
        ecs_backend = _get_ecs_backend(context)
        cluster_key = _normalize_cluster_name(cluster_name)
        if ecs_backend.container_instances.get(cluster_key):
            return  # already has an instance

        # Create a synthetic EC2 instance in Moto (required by register_container_instance)
        ec2_backend = moto_backends.get_backend("ec2")[context.account_id][context.region]
        reservation = ec2_backend.run_instances(
            image_id="ami-localemu-ecs",
            count=1,
            user_data="",
            security_group_names=[],
            instance_type="t3.micro",
            is_instance_type_default=False,
            placement=context.region + "a",
            region_name=context.region,
        )
        ec2_instance_id = reservation.instances[0].id

        ecs_backend.register_container_instance(cluster_key, ec2_instance_id)
        # Track synthetic instance for cleanup on cluster deletion
        _synthetic_instances[cluster_key] = ec2_instance_id
        LOG.debug(
            "Registered synthetic container instance %s for cluster %s",
            ec2_instance_id, cluster_key,
        )
    except (KeyboardInterrupt, SystemExit, MemoryError):
        # Re-raise critical errors that should never be swallowed
        raise
    except Exception as e:
        LOG.warning("Failed to ensure synthetic instance for %s: %s", cluster_name, e)


def _handle_run_task(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """RunTask: let Moto create the task record, then start real Docker containers."""
    # Extract launch type to distinguish FARGATE from EC2
    launch_type = request.get("launchType", "EC2")

    # Real AWS treats `securityGroups` as optional in `awsvpcConfiguration`
    # (falls back to the VPC's default security group when omitted). Moto's
    # Task constructor does `net_conf["securityGroups"]` with no `.get()`
    # fallback (moto/ecs/models.py), so an awsvpc task launched without an
    # explicit security group list crashes moto with a raw KeyError instead
    # of using a default. Normalise before moto ever sees the request.
    #
    # call_moto() dispatches from the ORIGINAL raw HTTP request, not this
    # already-parsed `request` dict, so mutating `request` alone has no
    # effect on what moto receives - call_moto_with_request() is required
    # to actually forward the normalised value.
    net_conf = (request.get("networkConfiguration") or {}).get("awsvpcConfiguration")
    normalized_request = request
    if net_conf is not None and "securityGroups" not in net_conf:
        net_conf["securityGroups"] = []
        normalized_request = dict(request)

    # Ensure Moto has a container instance so its run_task check passes.
    mgr = _init_task_manager()
    if mgr:
        cluster = request.get("cluster") or "default"
        _ensure_synthetic_instance(context, cluster, launch_type=launch_type)

    if normalized_request is not request:
        result = call_moto_with_request(context, normalized_request)
    else:
        result = call_moto(context)

    if not mgr:
        for task in result.get("tasks") or []:
            _omit_empty_network_configuration(task)
        return result

    tasks = result.get("tasks", [])
    if not tasks:
        return result

    for task in tasks:
        task_arn = task.get("taskArn", "")
        cluster_arn = task.get("clusterArn", "")
        task_def_arn = task.get("taskDefinitionArn", "")

        # Start with PROVISIONING status
        task["lastStatus"] = "PROVISIONING"
        task["desiredStatus"] = "RUNNING"

        # Add timing fields
        now_ts = time.time()
        task["createdAt"] = now_ts

        overrides_data = task.get("overrides", {})

        # Resolve the full task definition to get networkMode, cpu, memory
        full_td = _resolve_full_task_definition(context, task_def_arn)
        network_mode = full_td.get("networkMode", "bridge") if full_td else "bridge"

        # Add cpu/memory from the task definition
        td_cpu = full_td.get("cpu") if full_td else None
        td_memory = full_td.get("memory") if full_td else None
        if td_cpu:
            task["cpu"] = str(td_cpu)
        if td_memory:
            task["memory"] = str(td_memory)

        # moto's ``Task.containers`` is hard-coded to
        # ``[Container(task_definition)]`` and ``Container.__init__`` only
        # ever inspects ``task_def.container_definitions[0]``. So a multi-
        # container task definition (e.g. web + sidecar sharing a volume)
        # would lose every container after the first when iterating
        # ``task.get("containers", [])``. Source the launch list from the
        # registered task definition itself, then push synthetic Container
        # entries back into ``task["containers"]`` so DescribeTasks reflects
        # what we actually launched (and downstream status updates
        # find each container by name).
        registered_defs = _resolve_task_definition(context, task_def_arn)
        # #685/#711: pass through Docker-mapped containerDefinition fields
        container_defs = [_copy_container_def_fields(src_def) for src_def in registered_defs]

        # If moto only emitted the first container, append synthetic
        # entries so DescribeTasks shows every running container.
        existing_names = {mc.get("name") for mc in task.get("containers", [])}
        for cdef in container_defs:
            if cdef["name"] and cdef["name"] not in existing_names:
                task.setdefault("containers", []).append({
                    "name": cdef["name"],
                    "image": cdef.get("image", ""),
                    "lastStatus": "PENDING",
                    "containerArn": (
                        f"{task_def_arn}/{cdef['name']}"
                    ),
                })

        # Extract volumes from task definition
        td_volumes = full_td.get("volumes", []) if full_td else []

        task_definition = {
            "taskDefinitionArn": task_def_arn,
            "containerDefinitions": container_defs,
            # Pass network mode to Docker task manager
            "networkMode": network_mode,
            # Pass volumes
            "volumes": td_volumes,
            # #79: task role ARN drives IAM credential minting
            "taskRoleArn": full_td.get("taskRoleArn") if full_td else None,
            "executionRoleArn": full_td.get("executionRoleArn") if full_td else None,
        }

        # Pull networkConfiguration from the RunTask request so the
        # task manager can resolve the real VPC via subnet IDs instead
        # of picking the first localemu-vpc-* network it finds.
        network_configuration = request.get("networkConfiguration") or {}

        try:
            task_infos = mgr.run_task(
                cluster_name=cluster_arn,
                task_definition=task_definition,
                task_arn=task_arn,
                count=1,
                overrides=overrides_data,
                launch_type=launch_type,
                region=context.region,
                network_configuration=network_configuration,
                account_id=context.account_id,
            )

            # Update Moto's response with real container status (#201:
            # do not hardcode RUNNING — failed creates stay STOPPED).
            if task_infos:
                ti = task_infos[0]
                task["lastStatus"] = ti.status
                if ti.status == "STOPPED":
                    task["desiredStatus"] = "STOPPED"
                    if ti.stopped_reason:
                        task["stoppedReason"] = ti.stopped_reason
                    if ti.stopped_at:
                        task["stoppedAt"] = ti.stopped_at
                else:
                    task["desiredStatus"] = "RUNNING"
                    task["startedAt"] = ti.started_at or time.time()

                for mc in task.get("containers", []):
                    for ci in ti.containers:
                        if ci.container_name == mc.get("name"):
                            mc["lastStatus"] = ci.status
                            if ci.exit_code is not None:
                                mc["exitCode"] = ci.exit_code
                            # Add network bindings for mapped ports
                            bindings = []
                            for c_port, h_port in ci.host_ports.items():
                                bindings.append({
                                    "bindIP": "0.0.0.0",
                                    "containerPort": c_port,
                                    "hostPort": h_port,
                                    "protocol": "tcp",
                                })
                            if bindings:
                                mc["networkBindings"] = bindings
                            break

                _apply_awsvpc_eni_ip(task, ti, context.account_id, context.region)

                LOG.info(
                    "ECS task %s %s with %d containers",
                    task_arn, ti.status, len(ti.containers),
                )
        except Exception as e:
            LOG.warning("Docker launch failed for ECS task %s: %s", task_arn, e)
            task["lastStatus"] = "STOPPED"
            task["desiredStatus"] = "STOPPED"
            task["stoppedReason"] = f"CannotStartContainerError: {e}"
            task["stoppedAt"] = time.time()

        _omit_empty_network_configuration(task)

    return result


def _lookup_container_image(
    context: RequestContext, task_def_arn: str, container_name: str
) -> str:
    """Look up a container's image from the Moto task definition store."""
    details = _lookup_task_definition_details(
        context, task_def_arn, container_name
    )
    return details.get("image", "") if details else ""


# Cache of resolved task definitions to avoid repeated Moto lookups
_task_def_cache: dict[str, list[dict]] = {}

# Docker-relevant containerDefinition keys the task manager understands.
# Keep in sync with localemu-patches/ecs_task_manager.py + docs/status.md (#711).
_CONTAINER_DEF_PASSTHROUGH = (
    "name",
    "image",
    "command",
    "environment",
    "cpu",
    "memory",
    "memoryReservation",
    "secrets",
    "user",
    "privileged",
    "ulimits",
    "dockerLabels",
    "workingDirectory",
)


def _copy_container_def_fields(src: dict) -> dict:
    """Copy known containerDefinition fields for Docker launch (#711)."""
    cdef: dict = {
        "name": src.get("name", ""),
        "image": src.get("image", ""),
        "portMappings": src.get("portMappings", []),
        "environment": src.get("environment", []),
        "command": src.get("command"),
    }
    ep = src.get("entryPoint") or src.get("entry_point")
    if ep is not None:
        cdef["entryPoint"] = ep
    if src.get("secrets"):
        cdef["secrets"] = src["secrets"]
    if src.get("healthCheck"):
        cdef["healthCheck"] = src["healthCheck"]
    if src.get("mountPoints"):
        cdef["mountPoints"] = src["mountPoints"]
    for key in (
        "cpu",
        "memory",
        "memoryReservation",
        "user",
        "privileged",
        "ulimits",
        "dockerLabels",
        "workingDirectory",
    ):
        if src.get(key) is not None:
            cdef[key] = src[key]
    return cdef


def _resolve_task_definition(context: RequestContext, task_def_arn: str) -> list[dict]:
    """Resolve the full containerDefinitions for a task definition ARN.

    Uses Moto's internal backend to look up the registered task definition
    and extract its container definitions as plain dicts.
    """
    if task_def_arn in _task_def_cache:
        return _task_def_cache[task_def_arn]

    container_defs = []
    try:
        td_obj = _find_moto_task_definition(context, task_def_arn)
        if td_obj:
            for cdef in getattr(td_obj, "container_definitions", []):
                if isinstance(cdef, dict):
                    container_defs.append(cdef)
                else:
                    # Convert Moto container definition object to dict
                    d: dict = {}
                    for attr in _CONTAINER_DEF_PASSTHROUGH:
                        val = getattr(cdef, attr, None)
                        if val is not None:
                            d[attr] = val
                    # #685: entryPoint may be snake_case on object-shaped defs
                    ep = (
                        getattr(cdef, "entry_point", None)
                        or getattr(cdef, "entryPoint", None)
                    )
                    if ep is not None:
                        d["entryPoint"] = ep
                    # Moto uses port_mappings (snake_case)
                    pm = getattr(cdef, "port_mappings", None) or getattr(cdef, "portMappings", None)
                    if pm is not None:
                        d["portMappings"] = pm
                    secrets = getattr(cdef, "secrets", None)
                    if secrets is not None and "secrets" not in d:
                        d["secrets"] = secrets
                    # Extract health check
                    hc = getattr(cdef, "health_check", None) or getattr(cdef, "healthCheck", None)
                    if hc is not None:
                        d["healthCheck"] = hc if isinstance(hc, dict) else {
                            "command": getattr(hc, "command", []),
                            "interval": getattr(hc, "interval", 30),
                            "timeout": getattr(hc, "timeout", 5),
                            "retries": getattr(hc, "retries", 3),
                            "startPeriod": getattr(hc, "start_period", 0),
                        }
                    # Extract mount points
                    mp = getattr(cdef, "mount_points", None) or getattr(cdef, "mountPoints", None)
                    if mp is not None:
                        d["mountPoints"] = mp
                    # Snake_case aliases Moto may use for #711 fields
                    for snake, camel in (
                        ("docker_labels", "dockerLabels"),
                        ("working_directory", "workingDirectory"),
                    ):
                        if camel not in d:
                            alt = getattr(cdef, snake, None)
                            if alt is not None:
                                d[camel] = alt
                    container_defs.append(d)
    except Exception as e:
        LOG.debug("Could not look up task definition %s: %s", task_def_arn, e)

    _task_def_cache[task_def_arn] = container_defs
    return container_defs


def _find_moto_task_definition(context: RequestContext, task_def_arn: str):
    """Find the Moto task definition object for a given ARN."""
    try:
        ecs_backend = _get_ecs_backend(context)
        for family_revisions in ecs_backend.task_definitions.values():
            if isinstance(family_revisions, dict):
                items = family_revisions.values()
            elif isinstance(family_revisions, list):
                items = family_revisions
            else:
                items = [family_revisions]

            for td_obj in items:
                td_arn = getattr(td_obj, "arn", None)
                if td_arn == task_def_arn:
                    return td_obj
    except Exception as e:
        LOG.debug("Could not find task definition %s: %s", task_def_arn, e)
    return None


# Cache for full task definitions (networkMode, volumes, cpu, memory)
_full_td_cache: dict[str, dict] = {}


def _resolve_full_task_definition(context: RequestContext, task_def_arn: str) -> dict | None:
    """Resolve the full task definition metadata (networkMode, volumes, cpu, memory).

    Extracts top-level task definition attributes that affect
    Docker container configuration.
    """
    if task_def_arn in _full_td_cache:
        return _full_td_cache[task_def_arn]

    result = {}
    try:
        td_obj = _find_moto_task_definition(context, task_def_arn)
        if td_obj:
            result["networkMode"] = getattr(td_obj, "network_mode", None) or getattr(td_obj, "networkMode", "bridge") or "bridge"
            result["cpu"] = getattr(td_obj, "cpu", None)
            result["memory"] = getattr(td_obj, "memory", None)
            # Extract volumes
            vols = getattr(td_obj, "volumes", None)
            if vols:
                result["volumes"] = vols if isinstance(vols, list) else []
            # #79: Surface taskRoleArn / executionRoleArn so the Docker
            # task manager can mint IAM credentials for the task.
            result["taskRoleArn"] = (
                getattr(td_obj, "task_role_arn", None)
                or getattr(td_obj, "taskRoleArn", None)
            )
            result["executionRoleArn"] = (
                getattr(td_obj, "execution_role_arn", None)
                or getattr(td_obj, "executionRoleArn", None)
            )
    except Exception as e:
        LOG.debug("Could not resolve full task definition %s: %s", task_def_arn, e)

    _full_td_cache[task_def_arn] = result
    return result


def _lookup_task_definition_details(
    context: RequestContext, task_def_arn: str, container_name: str
) -> dict | None:
    """Look up a specific container's details from a task definition."""
    for cdef in _resolve_task_definition(context, task_def_arn):
        if cdef.get("name") == container_name:
            return cdef
    return None


def _finalize_stopped_task_backends(
    task_arn: str,
    reason: str,
    prior_stop_error: Exception | None = None,
) -> None:
    """Force every matching moto task record to STOPPED and release resources.

    Runs even when moto ``stop_task`` raised mid-update (e.g. PORTS
    ``.remove`` ValueError) so a ghost task cannot keep host ports (#716).

    When ``prior_stop_error`` is set, ``call_moto`` already ran moto
    ``stop_task`` (possibly partially). Do **not** call it again — that
    would double-return CPU/MEMORY after a mid-PORTS failure.
    """
    if not task_arn:
        return
    short = str(task_arn).split("/")[-1]
    try:
        for _acct, _region, backend in _iter_ecs_backends():
            for cluster_tasks in (getattr(backend, "tasks", {}) or {}).values():
                for tid, task in list(cluster_tasks.items()):
                    arn = getattr(task, "task_arn", None) or tid
                    if (
                        short not in (str(arn), str(tid))
                        and not str(arn).endswith(short)
                        and not str(tid).endswith(short)
                    ):
                        continue
                    raw = (
                        getattr(task, "_status", None)
                        or getattr(task, "last_status", "")
                        or ""
                    ).upper()
                    if raw != "STOPPED" or prior_stop_error is not None:
                        _force_stop_missing_task(
                            backend,
                            task,
                            reason,
                            prior_stop_error=prior_stop_error,
                        )
    except Exception:
        LOG.debug("StopTask moto finalize failed for %s", task_arn, exc_info=True)


def _handle_stop_task(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """StopTask: let Moto update the record, then stop Docker containers."""
    # ECS uses JSON protocol - parameters are in the parsed `request` dict,
    # NOT in context.request.values (which is empty for JSON bodies).
    task_arn = request.get("task") or ""
    # cluster is on the request; moto resolves it via call_moto(context).
    _ = request.get("cluster", "default")
    # Capture the stop reason
    reason = request.get("reason", "") or "Task stopped by user"
    result: dict | None = None
    call_error: Exception | None = None

    try:
        try:
            result = call_moto(context)
        except Exception as exc:
            # moto stop_task can raise mid-resource update (PORTS .remove).
            # Finalize in ``finally`` still releases ports / forces STOPPED.
            call_error = exc
            LOG.warning(
                "StopTask moto call failed for %s: %s — will force-finalize",
                task_arn, exc,
            )
            result = {}

        # Propagate reason to the response
        if reason and result.get("task"):
            result["task"]["stoppedReason"] = reason

        # Set STOPPING transitional state
        if result.get("task"):
            result["task"]["lastStatus"] = "STOPPING"
            result["task"]["desiredStatus"] = "STOPPED"
            # Add stoppedAt timestamp
            result["task"]["stoppedAt"] = time.time()

        mgr = _init_task_manager()
        if mgr and task_arn:
            try:
                mgr.stop_task(task_arn)
            except Exception as e:
                LOG.warning(
                    "Failed to stop Docker containers for ECS task %s: %s",
                    task_arn, e,
                )
    finally:
        # Always finish STOPPED on the moto record — even when call_moto
        # raised before returning. Ghost / DEACTIVATING tasks with no
        # container must not linger holding host ports (#716).
        _finalize_stopped_task_backends(
            task_arn, reason, prior_stop_error=call_error
        )

    if result is None:
        result = {}
    if result.get("task"):
        result["task"]["lastStatus"] = "STOPPED"
        result["task"]["desiredStatus"] = "STOPPED"
        if reason:
            result["task"]["stoppedReason"] = reason
    elif call_error is not None:
        # Moto failed and gave no task payload — still surface a stopped
        # view when we can find the record we just finalized.
        short = str(task_arn).split("/")[-1]
        for _acct, _region, backend in _iter_ecs_backends():
            for cluster_tasks in (getattr(backend, "tasks", {}) or {}).values():
                for tid, task in list(cluster_tasks.items()):
                    arn = getattr(task, "task_arn", None) or tid
                    if short not in (str(arn), str(tid)) and not str(arn).endswith(
                        short
                    ):
                        continue
                    result = {
                        "task": {
                            "taskArn": str(arn),
                            "lastStatus": "STOPPED",
                            "desiredStatus": "STOPPED",
                            "stoppedReason": reason
                            or getattr(task, "stopped_reason", "")
                            or "Task stopped by user",
                            "clusterArn": getattr(task, "cluster_arn", "") or "",
                            "taskDefinitionArn": getattr(
                                task, "task_definition_arn", ""
                            )
                            or "",
                        }
                    }
                    return result
        raise call_error

    return result


def _handle_describe_tasks(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """DescribeTasks: let Moto return records, then enrich with real container status."""
    result = call_moto(context)

    mgr = _init_task_manager()
    if not mgr:
        for task in result.get("tasks") or []:
            _omit_empty_network_configuration(task)
        return result

    for task in result.get("tasks", []):
        task_arn = task.get("taskArn", "")
        task_def_arn = task.get("taskDefinitionArn", "")
        task_info = mgr.get_task_status(task_arn)

        # Enrich with cpu/memory from task definition even without Docker info
        if task_def_arn:
            full_td = _resolve_full_task_definition(context, task_def_arn)
            if full_td:
                if full_td.get("cpu") and "cpu" not in task:
                    task["cpu"] = str(full_td["cpu"])
                if full_td.get("memory") and "memory" not in task:
                    task["memory"] = str(full_td["memory"])

        if task_info:
            task["lastStatus"] = task_info.status
            # Add timing fields from task info
            if task_info.created_at:
                task["createdAt"] = task_info.created_at
            if task_info.started_at:
                task["startedAt"] = task_info.started_at
            if task_info.stopped_at:
                task["stoppedAt"] = task_info.stopped_at
            if task_info.stopped_reason:
                task["stoppedReason"] = task_info.stopped_reason
            if task_info.status == "STOPPED":
                task["desiredStatus"] = "STOPPED"

            for mc in task.get("containers", []):
                for ci in task_info.containers:
                    if ci.container_name == mc.get("name"):
                        mc["lastStatus"] = ci.status
                        if ci.exit_code is not None:
                            mc["exitCode"] = ci.exit_code
                        # Populate networkBindings on every
                        # DescribeTasks call. Moto's Container model does not
                        # carry port bindings, so without this re-projection
                        # the field is dropped on the second call (real AWS
                        # always returns it for tasks with portMappings).
                        if ci.host_ports:
                            mc["networkBindings"] = [
                                {
                                    "bindIP": "0.0.0.0",
                                    "containerPort": c_port,
                                    "hostPort": h_port,
                                    "protocol": "tcp",
                                }
                                for c_port, h_port in ci.host_ports.items()
                            ]
                        break

            _apply_awsvpc_eni_ip(
                task, task_info, context.account_id, context.region,
            )

        # Always (#708): omit even when Docker status is missing
        _omit_empty_network_configuration(task)

    return result


def _handle_create_cluster(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """CreateCluster: leave placement to a real container instance.

    A synthetic EC2 instance is registered lazily on RunTask / CreateService
    only when the cluster still has none. Registering one here would win
    placement over an ASG instance or RegisterContainerInstance that arrives
    next (#207).
    """
    result = call_moto(context)
    cluster_name = result.get("cluster", {}).get("clusterName", "")
    LOG.info("ECS cluster created: %s", cluster_name)
    return result


def _handle_delete_cluster(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """DeleteCluster: let Moto delete the record, then cleanup any remaining containers."""
    cluster_name = request.get("cluster", "")
    result = call_moto(context)

    mgr = _init_task_manager()
    if mgr and cluster_name:
        try:
            mgr.cleanup_cluster(cluster_name)
        except Exception as e:
            LOG.warning("Failed to clean up containers for ECS cluster %s: %s", cluster_name, e)

    # Terminate synthetic EC2 instance for this cluster
    cluster_short = _normalize_cluster_name(cluster_name)
    ec2_instance_id = _synthetic_instances.pop(cluster_short, None)
    if ec2_instance_id:
        try:
            ec2_backend = moto_backends.get_backend("ec2")[context.account_id][context.region]
            ec2_backend.terminate_instances([ec2_instance_id])
            LOG.debug("Terminated synthetic EC2 instance %s for cluster %s", ec2_instance_id, cluster_short)
        except Exception as e:
            LOG.debug("Failed to terminate synthetic instance %s: %s", ec2_instance_id, e)

    # Invalidate task definition caches on cluster deletion
    _task_def_cache.clear()
    _full_td_cache.clear()

    return result


def _handle_list_clusters(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """ListClusters: Moto returns every cluster ARN, including ones DeleteCluster
    only marked INACTIVE (moto/ecs/models.py delete_cluster). Real ECS keeps
    INACTIVE clusters describable for a while but omits them from ListClusters
    (#401), so filter them out here.
    """
    result = call_moto(context)

    ecs_backend = _get_ecs_backend(context)
    inactive_arns = {
        cluster.arn for cluster in ecs_backend.clusters.values() if cluster.status == "INACTIVE"
    }
    if inactive_arns:
        result["clusterArns"] = [
            arn for arn in result.get("clusterArns", []) if arn not in inactive_arns
        ]

    return result


def _handle_register_task_definition(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """RegisterTaskDefinition: invalidate cache after Moto registers the definition."""
    result = call_moto(context)
    # Invalidate task def cache on new registration
    td_arn = result.get("taskDefinition", {}).get("taskDefinitionArn")
    if td_arn:
        _task_def_cache.pop(td_arn, None)
        _full_td_cache.pop(td_arn, None)
    return result


def _handle_deregister_task_definition(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """DeregisterTaskDefinition: invalidate cache when definition removed."""
    result = call_moto(context)
    td_arn = result.get("taskDefinition", {}).get("taskDefinitionArn")
    if td_arn:
        _task_def_cache.pop(td_arn, None)
        _full_td_cache.pop(td_arn, None)
    return result


# ---------------------
# Service management
# ---------------------

# Track service -> task ARNs mapping for desired count reconciliation
_service_tasks: dict[str, list[str]] = {}
_service_tasks_lock = threading.Lock()


def _omit_empty_network_configuration(obj: dict | None) -> None:
    """Drop empty / non-awsvpc ``networkConfiguration`` (AWS omits; #708)."""
    if not isinstance(obj, dict):
        return
    net = obj.get("networkConfiguration")
    if not isinstance(net, dict) or "awsvpcConfiguration" not in net:
        obj.pop("networkConfiguration", None)
    for dep in obj.get("deployments") or []:
        if not isinstance(dep, dict):
            continue
        dnet = dep.get("networkConfiguration")
        if not isinstance(dnet, dict) or "awsvpcConfiguration" not in dnet:
            dep.pop("networkConfiguration", None)


def _handle_create_service(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """CreateService: Moto record, then EC2 scheduling / target registration (#207)."""
    result = call_moto(context)
    service_data = result.get("service")
    _omit_empty_network_configuration(service_data)
    if not service_data or not _init_task_manager():
        return result
    from localemu.services.ecs.ec2_services import on_create_service

    on_create_service(context, request, service_data)
    return result


def _handle_update_service(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """UpdateService: scale, or replace tasks when the task definition changes."""
    result = call_moto(context)
    service_data = result.get("service")
    _omit_empty_network_configuration(service_data)
    if not service_data or not _init_task_manager():
        return result
    from localemu.services.ecs.ec2_services import on_update_service

    on_update_service(context, request, service_data)
    return result


def _handle_describe_services(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """DescribeServices: omit empty networkConfiguration (#708)."""
    result = call_moto(context)
    for service in result.get("services") or []:
        _omit_empty_network_configuration(service)
    return result


def _handle_delete_service(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """DeleteService: let Moto delete the record, then stop all service tasks."""
    # Identify the service ARN before Moto deletes
    cluster = request.get("cluster", "default")
    service_name = request.get("service", "")

    result = call_moto(context)
    _omit_empty_network_configuration(result.get("service"))

    from localemu.services.ecs.ec2_services import on_delete_service

    on_delete_service(cluster, service_name)

    mgr = _init_task_manager()
    if not mgr:
        return result

    # Find matching service ARN (fallback if the scheduler never tracked it)
    service_arn = None
    with _service_tasks_lock:
        for arn in list(_service_tasks.keys()):
            if service_name in arn:
                service_arn = arn
                break
        task_arns = _service_tasks.pop(service_arn, []) if service_arn else []

    for task_arn in task_arns:
        try:
            mgr.stop_task(task_arn)
        except Exception as e:
            LOG.debug("Failed to stop service task %s: %s", task_arn, e)

    if task_arns:
        LOG.info("ECS service deleted, stopped %d tasks", len(task_arns))

    return result


def _handle_list_services(
    context: RequestContext, request: ServiceRequest
) -> ServiceResponse:
    """ListServices: Moto's list_services returns every service ARN in the
    cluster regardless of status, including ones DeleteService only marked
    INACTIVE rather than removing (moto/ecs/models.py delete_service: "A
    service is not immediately removed - just marked as inactive"). Real ECS
    excludes INACTIVE services from ListServices, so filter them out here.
    """
    result = call_moto(context)

    ecs_backend = _get_ecs_backend(context)
    inactive_arns = {
        service.arn for service in ecs_backend.services.values() if service.status == "INACTIVE"
    }
    if inactive_arns:
        result["serviceArns"] = [
            arn for arn in result.get("serviceArns", []) if arn not in inactive_arns
        ]

    return result


def _run_service_tasks(
    context: RequestContext,
    cluster_name: str,
    task_def_arn: str,
    count: int,
    launch_type: str,
    network_configuration: dict | None = None,
    group: str | None = None,
) -> list[str]:
    """Run N tasks for a service, returning the task ARNs created.

    ``_resolve_full_task_definition`` only exposes top-level
    task-def fields (networkMode, cpu, memory, volumes) - *not* the container
    definitions. Before this fix we pulled ``containerDefinitions`` out of
    that dict and got an empty list every time, so CreateService/UpdateService
    would create moto task records but never launch a Docker container. Use
    ``_resolve_task_definition`` for the per-container details and the full-td
    helper strictly for top-level attributes. Also forward the service's
    ``networkConfiguration`` to moto's ``run_task`` - moto requires it on
    awsvpc task definitions and would otherwise raise.
    """
    task_arns = []
    for _ in range(count):
        try:
            ecs_backend = _get_ecs_backend(context)
            moto_tasks = ecs_backend.run_task(
                cluster_str=cluster_name,
                task_definition_str=task_def_arn,
                count=1,
                overrides=None,
                started_by="ecs-service-scheduler",
                tags=None,
                launch_type=launch_type,
                networking_configuration=network_configuration,
                group=group,
            )
            if not moto_tasks:
                continue

            for moto_task in moto_tasks:
                task_arn = moto_task.task_arn
                task_arns.append(task_arn)

                # Now start the Docker container
                mgr = _init_task_manager()
                if not mgr:
                    continue

                full_td = _resolve_full_task_definition(context, task_def_arn) or {}
                container_defs = _resolve_task_definition(context, task_def_arn)
                if not container_defs:
                    LOG.warning(
                        "Service task %s: could not resolve containerDefinitions "
                        "for %s - no Docker container will be launched",
                        task_arn, task_def_arn,
                    )
                    continue

                network_mode = full_td.get("networkMode", "bridge")
                td_volumes = full_td.get("volumes", [])

                task_definition = {
                    "taskDefinitionArn": task_def_arn,
                    "containerDefinitions": container_defs,
                    "networkMode": network_mode,
                    "volumes": td_volumes,
                    # Same as RunTask: the execution role drives secrets/registry auth, the task role drives credentials.
                    "taskRoleArn": full_td.get("taskRoleArn"),
                    "executionRoleArn": full_td.get("executionRoleArn"),
                }

                try:
                    mgr.run_task(
                        cluster_name=cluster_name,
                        task_definition=task_definition,
                        task_arn=task_arn,
                        count=1,
                        overrides={},
                        launch_type=launch_type,
                        region=context.region,
                        network_configuration=network_configuration,
                        account_id=context.account_id,
                    )
                except Exception as e:
                    LOG.warning("Docker launch failed for service task %s: %s", task_arn, e)

        except Exception as e:
            LOG.warning("Failed to run service task: %s", e)

    return task_arns


# Operations we intercept with Docker container management
_INTERCEPTED_OPS = {
    "RunTask": _handle_run_task,
    "StopTask": _handle_stop_task,
    "DescribeTasks": _handle_describe_tasks,
    "CreateCluster": _handle_create_cluster,
    "DeleteCluster": _handle_delete_cluster,
    "ListClusters": _handle_list_clusters,
    "RegisterTaskDefinition": _handle_register_task_definition,
    "DeregisterTaskDefinition": _handle_deregister_task_definition,
    "CreateService": _handle_create_service,
    "UpdateService": _handle_update_service,
    "DescribeServices": _handle_describe_services,
    "DeleteService": _handle_delete_service,
    "ListServices": _handle_list_services,
}


def EcsDispatcher(service_model) -> DispatchTable:
    """Create a dispatch table for ECS.

    Intercepted operations (RunTask, StopTask, DescribeTasks, etc.)
    go through our Docker container management handlers.
    All other operations route directly to Moto.
    """
    table = {}
    for op in service_model.operation_names:
        if op in _INTERCEPTED_OPS:
            table[op] = _INTERCEPTED_OPS[op]
        else:
            table[op] = _proxy_moto
    return table


def _iter_ecs_backends():
    """Yield ``(account_id, region, backend)`` for every instantiated ECS
    moto backend. Mirrors the pattern SaveOrchestrator uses."""
    try:
        bd = moto_backends.get_backend("ecs")
    except Exception:
        return
    for acct, region_map in list(bd.items()):
        if not isinstance(region_map, dict):
            continue
        for region, backend in list(region_map.items()):
            yield acct, region, backend


_MISSING_CONTAINER_REASON = "Task container not restored"


def _task_cluster_name(task) -> str:
    name = getattr(task, "cluster_name", None) or ""
    if name:
        return str(name)
    cluster_arn = getattr(task, "cluster_arn", "") or ""
    if "/" in cluster_arn:
        return cluster_arn.split("/")[-1]
    return "default"


def _registered_resource_map(container_instance) -> dict:
    out: dict = {}
    for resource in getattr(container_instance, "registered_resources", []) or []:
        name = resource.get("name")
        if name:
            out[name] = resource
    return out


def _clamp_remaining_to_registered(container_instance) -> None:
    """Ensure remaining CPU/MEMORY never exceed registered capacity (#716)."""
    registered = _registered_resource_map(container_instance)
    for resource in getattr(container_instance, "remaining_resources", []) or []:
        name = resource.get("name")
        if name not in ("CPU", "MEMORY"):
            continue
        cap = registered.get(name)
        if cap is None:
            continue
        rem = int(resource.get("integerValue") or 0)
        top = int(cap.get("integerValue") or 0)
        if rem > top:
            resource["integerValue"] = top


def _sweep_task_ports(container_instance, task_resources) -> None:
    """Drop leftover host ports for a task; ignore ports already absent."""
    if not task_resources:
        return
    for resource in getattr(container_instance, "remaining_resources", []) or []:
        name = resource.get("name")
        if name not in ("PORTS", "PORTS_UDP"):
            continue
        held = resource.get("stringSetValue")
        if not isinstance(held, list):
            continue
        key = "PORTS" if name == "PORTS" else "PORTS_UDP"
        for port in task_resources.get(key) or []:
            sp = str(port)
            if sp in held:
                held.remove(sp)


def _release_instance_resources_tolerant(container_instance, task_resources) -> None:
    """Return CPU/memory/PORTS held by a task without raising on missing ports.

    Moto's ``update_container_instance_resources(..., removing=True)`` does
    ``PORTS.remove(port)`` and raises ``ValueError`` when a port was already
    dropped mid-``stop_task``. Skip ports that are already absent. Cap
    remaining CPU/MEMORY at registered capacity so a partial prior release
    cannot push remaining above capacity (#716).
    """
    if not task_resources:
        return
    registered = _registered_resource_map(container_instance)
    for resource in getattr(container_instance, "remaining_resources", []) or []:
        name = resource.get("name")
        if name == "CPU":
            rem = int(resource.get("integerValue") or 0) + int(
                task_resources.get("CPU") or 0
            )
            cap = registered.get("CPU")
            if cap is not None:
                rem = min(rem, int(cap.get("integerValue") or 0))
            resource["integerValue"] = rem
        elif name == "MEMORY":
            rem = int(resource.get("integerValue") or 0) + int(
                task_resources.get("MEMORY") or 0
            )
            cap = registered.get("MEMORY")
            if cap is not None:
                rem = min(rem, int(cap.get("integerValue") or 0))
            resource["integerValue"] = rem
        elif name in ("PORTS", "PORTS_UDP"):
            held = resource.get("stringSetValue")
            if not isinstance(held, list):
                continue
            key = "PORTS" if name == "PORTS" else "PORTS_UDP"
            for port in task_resources.get(key) or []:
                sp = str(port)
                if sp in held:
                    held.remove(sp)
    count = int(getattr(container_instance, "running_tasks_count", 0) or 0)
    if count > 0:
        container_instance.running_tasks_count = count - 1
    _clamp_remaining_to_registered(container_instance)


def _recover_after_failed_stop(container_instance, task_resources, stop_exc) -> None:
    """Release leftovers after a failed/partial moto ``stop_task`` (#716).

    Mid-PORTS ``ValueError`` means CPU/MEMORY were already returned — only
    sweep leftover ports and fix ``running_tasks_count``. Other failures
    get a full tolerant release. Always clamp remaining ≤ registered.
    """
    ports_partial = isinstance(stop_exc, ValueError) and (
        "not in list" in str(stop_exc)
    )
    if ports_partial:
        _sweep_task_ports(container_instance, task_resources)
        count = int(getattr(container_instance, "running_tasks_count", 0) or 0)
        if count > 0:
            # moto decrements running_tasks_count after the resource loop,
            # so a mid-PORTS raise left the count high.
            container_instance.running_tasks_count = count - 1
        _clamp_remaining_to_registered(container_instance)
        return
    _release_instance_resources_tolerant(container_instance, task_resources)


def _force_stop_missing_task(
    backend,
    task,
    reason: str = _MISSING_CONTAINER_REASON,
    prior_stop_error: Exception | None = None,
) -> None:
    """Mark a ghost task STOPPED and release container-instance resources (#716).

    Prefer moto ``stop_task`` once. If that fails mid-PORTS (CPU/MEMORY
    already returned), do **not** call it again — recover with a
    ports-only / capacity-clamped fallback so remainingResources never
    exceed registered capacity.
    """
    status = (
        getattr(task, "_status", None) or getattr(task, "last_status", "") or ""
    ).upper()
    cluster_name = _task_cluster_name(task)
    task_arn = getattr(task, "task_arn", None) or ""
    ci_arn = getattr(task, "container_instance_arn", None)
    reqs = getattr(task, "resource_requirements", None)

    def _ci():
        if not ci_arn:
            return None
        ci_id = str(ci_arn).split("/")[-1]
        cis = (getattr(backend, "container_instances", {}) or {}).get(cluster_name) or {}
        return cis.get(ci_id)

    if status == "STOPPED" and prior_stop_error is None:
        # Still clear any ports left behind by a partial stop_task.
        ci = _ci()
        if ci is not None and reqs:
            try:
                _sweep_task_ports(ci, reqs)
                _clamp_remaining_to_registered(ci)
            except Exception:
                LOG.debug(
                    "ECS reconcile port sweep failed for already-STOPPED task",
                    exc_info=True,
                )
        return

    stop_exc = prior_stop_error
    if prior_stop_error is None and status != "STOPPED":
        try:
            backend.stop_task(cluster_name, task_arn, reason)
            return
        except Exception as exc:
            stop_exc = exc
            LOG.warning(
                "ECS reconcile stop_task failed for %s: %s — forcing STOPPED",
                task_arn, exc,
            )

    ci = _ci()
    if ci is not None and reqs and stop_exc is not None:
        try:
            _recover_after_failed_stop(ci, reqs, stop_exc)
        except Exception:
            LOG.debug(
                "ECS reconcile resource release fallback failed for %s",
                task_arn, exc_info=True,
            )
    elif ci is not None and reqs and status != "STOPPED":
        # prior_stop_error path with no exception object shouldn't happen,
        # but still free resources without a second moto stop_task.
        try:
            _release_instance_resources_tolerant(ci, reqs)
        except Exception:
            LOG.debug(
                "ECS reconcile resource release fallback failed for %s",
                task_arn, exc_info=True,
            )

    task.last_status = "STOPPED"
    task.desired_status = "STOPPED"
    task.stopped_reason = reason


def _ecs_on_after_state_load() -> None:
    """Reconcile persisted ECS records with the live Docker daemon.

    Runs after ``SaveOrchestrator`` re-hydrates moto's ECS backend. For
    each persisted task we:

    1. Rebuild the module-level ``_synthetic_instances`` and
       ``_service_tasks`` mappings from moto (these are runtime caches,
       not persisted state).
    2. Resume every task whose containers still exist on the host via
       ``docker start`` - their writable layer, env vars, and port
       bindings all survive the restart.
    3. Tasks whose containers are missing (``docker rm``, prune, or
       never recovered) are marked ``STOPPED`` with stoppedReason
       ``Task container not restored`` and their container-instance
       resources / host ports are released (#716). Never leave a task
       in RUNNING / PENDING / DEACTIVATING without a container.
    """
    # Clear module-level caches - moto rewrote the state under us.
    _task_def_cache.clear()
    _full_td_cache.clear()
    _synthetic_instances.clear()
    _service_tasks.clear()

    # Force-init the task manager (it re-scans Docker labels on __init__
    # via `_recover_orphaned_containers`). ``ECS_DOCKER_BACKEND=0`` short-
    # circuits this - in that mode there are no containers to reconcile.
    mgr = _init_task_manager()
    if not mgr:
        LOG.debug("ECS Docker backend disabled - skipping post-load reconcile")
        return

    # Step 1: rebuild synthetic EC2 instance mapping from moto.
    for _acct, _region, backend in _iter_ecs_backends():
        container_instances = getattr(backend, "container_instances", {}) or {}
        for cluster_name, instances in container_instances.items():
            if not instances:
                continue
            first = next(iter(instances.values()), None)
            ec2_id = getattr(first, "ec2_instance_id", None)
            if ec2_id:
                _synthetic_instances[_normalize_cluster_name(cluster_name)] = ec2_id

    # Step 2: reconcile every persisted task against tracked containers.
    # Read ManagedState via ``_status`` — ``last_status`` / ``status`` can
    # advance RUNNING→DEACTIVATING when a persisted tick is already pending.
    resumed = missing = skipped = 0
    for _acct, _region, backend in _iter_ecs_backends():
        tasks = getattr(backend, "tasks", {}) or {}
        for _cluster_key, cluster_tasks in tasks.items():
            for task_id, task in list(cluster_tasks.items()):
                status = (getattr(task, "_status", None) or "").upper()
                if not status:
                    status = (getattr(task, "last_status", "") or "").upper()
                if status in ("STOPPED", "DEPROVISIONING"):
                    skipped += 1
                    continue
                task_arn = getattr(task, "task_arn", None) or task_id
                desired = (getattr(task, "desired_status", "") or "").upper()
                tracked = mgr._tasks.get(task_arn) if hasattr(mgr, "_tasks") else None

                # Finish stop only when desired is STOPPED (never leave
                # DEACTIVATING holding ports). Do not treat a ManagedState
                # tick into DEACTIVATING with desired RUNNING as a stop.
                if desired == "STOPPED":
                    if tracked is not None:
                        try:
                            mgr.stop_task(task_arn)
                        except Exception:
                            LOG.debug(
                                "ECS reconcile docker stop failed for %s",
                                task_arn, exc_info=True,
                            )
                    stop_reason = (
                        _MISSING_CONTAINER_REASON
                        if tracked is None
                        else (getattr(task, "stopped_reason", None) or "Task stopped")
                    )
                    _force_stop_missing_task(backend, task, reason=stop_reason)
                    missing += 1
                    continue

                if tracked and _resume_task_containers(tracked):
                    task.last_status = "RUNNING"
                    task.desired_status = "RUNNING"
                    resumed += 1
                    continue
                LOG.warning(
                    "ECS task %s: container missing on restore — marking STOPPED "
                    "(%s)",
                    task_arn,
                    _MISSING_CONTAINER_REASON,
                )
                _force_stop_missing_task(backend, task)
                if tracked is not None and hasattr(mgr, "_tasks"):
                    mgr._tasks.pop(task_arn, None)
                missing += 1

    # Step 3: rebuild _service_tasks from moto. Required so the scheduler
    # (and DescribeServices) return accurate counts.
    for _acct, _region, backend in _iter_ecs_backends():
        services = getattr(backend, "services", {}) or {}
        tasks = getattr(backend, "tasks", {}) or {}
        for cluster_arn, cluster_services in services.items():
            cluster_tasks = tasks.get(cluster_arn, {}) or {}
            for service_arn, service in cluster_services.items():
                service_name = getattr(service, "name", "") or ""
                group_tag = f"service:{service_name}" if service_name else ""
                live = [
                    getattr(t, "task_arn", None) or tid
                    for tid, t in cluster_tasks.items()
                    if (getattr(t, "started_by", "") == "ecs-service-scheduler"
                        and (not group_tag or getattr(t, "group", "") == group_tag)
                        and (getattr(t, "last_status", "") or "").upper() != "STOPPED")
                ]
                if live:
                    _service_tasks[service_arn] = live

    LOG.info(
        "ECS reconcile: resumed=%d, missing=%d, skipped=%d",
        resumed, missing, skipped,
    )


def _resume_task_containers(task_info) -> bool:
    """Start every stopped container in ``task_info``. Returns True if
    the task has at least one running container after the pass."""
    from localemu.utils.docker_utils import DOCKER_CLIENT

    any_running = False
    for container in getattr(task_info, "containers", []):
        docker_name = getattr(container, "docker_name", None)
        if not docker_name:
            continue
        try:
            inspect = DOCKER_CLIENT.inspect_container(docker_name)
            running = bool((inspect.get("State") or {}).get("Running"))
        except Exception:
            LOG.warning(
                "ECS container %s missing during restore - marking stopped",
                docker_name,
            )
            container.status = "STOPPED"
            continue
        if running:
            container.status = "RUNNING"
            any_running = True
            continue
        try:
            DOCKER_CLIENT.start_container(docker_name)
            container.status = "RUNNING"
            any_running = True
            LOG.info("Resumed ECS container %s", docker_name)
        except Exception as exc:
            LOG.warning(
                "docker start %s failed: %s - container left stopped",
                docker_name, exc,
            )
            container.status = "STOPPED"
    if any_running:
        task_info.status = "RUNNING"
        return True
    task_info.status = "STOPPED"
    return False


class EcsStateLifecycleHook(ServiceLifecycleHook):
    """Bridges LocalEmu's persistence engine + state-reset flow to the ECS
    provider.

    ``on_before_state_reset`` clears module-level caches and destroys the
    Docker task manager so a reset returns the provider to cold-start.

    ``on_after_state_load`` is the persistence path: reconcile persisted
    moto records with the live Docker daemon. Containers that survived
    shutdown get ``docker start``ed; containers that are gone mark the
    task STOPPED and release instance resources (#716).
    """

    def on_before_state_reset(self) -> None:
        global _task_manager
        try:
            from localemu.services.ecs.ec2_services import reset_state

            reset_state()
        except Exception:
            LOG.debug("ECS EC2 scheduler reset failed", exc_info=True)
        _task_def_cache.clear()
        _full_td_cache.clear()
        _synthetic_instances.clear()
        _service_tasks.clear()
        if _task_manager:
            try:
                _task_manager.cleanup_all()
            except Exception as e:
                LOG.debug("Failed to clean up ECS containers on state reset: %s", e)
            _task_manager = None

    def on_after_state_reset(self) -> None:
        pass

    def on_after_state_load(self) -> None:
        _ecs_on_after_state_load()


# Module-level lifecycle hook instance
_lifecycle_hook = EcsStateLifecycleHook()


def _patch_moto_eni_private_dns_name() -> None:
    """Give moto's ``NetworkInterface`` a settable ``private_dns_name``.

    Two requirements collide here. Fargate RunTask synthesizes a task
    ENI directly without going through moto's full ``__init__`` flow
    and emits attachment details that include ``privateDnsName``; the
    moto attribute was unset and the dictionary build raised an
    ``AttributeError``. Standard ``RunInstances`` paths in newer moto
    builds DO go through ``__init__`` and assign
    ``self.private_dns_name = generate_dns_from_ip(...)`` directly when
    the subnet's VPC has ``enable_dns_hostnames=True``.

    A pure read-only ``property`` covered the Fargate case but blocked
    the assignment in standard RunInstances with
    ``AttributeError: property '_private_dns_name' of 'NetworkInterface'
    object has no setter`` (Python 3.13 surfaces the getter function's
    name in the error, which is why the log said ``_private_dns_name``
    rather than ``private_dns_name``).

    The settable form below covers both: if moto's __init__ assigned a
    value, the getter returns it; otherwise the getter derives the name
    from the IPv4 address in AWS's ``ip-10-1-1-22.ec2.internal`` shape.
    """
    try:
        from moto.ec2.models.elastic_network_interfaces import NetworkInterface
    except Exception:
        return
    if getattr(NetworkInterface, "_localemu_private_dns_patched", False):
        return

    _STORAGE_ATTR = "_localemu_private_dns_name"

    def _getter(self):
        stored = getattr(self, _STORAGE_ATTR, None)
        if stored:
            return stored
        ip = getattr(self, "private_ip_address", None) or ""
        if not ip:
            return ""
        return "ip-" + ip.replace(".", "-") + ".ec2.internal"

    def _setter(self, value):
        object.__setattr__(self, _STORAGE_ATTR, value)

    NetworkInterface.private_dns_name = property(_getter, _setter)
    NetworkInterface._localemu_private_dns_patched = True


def _patch_moto_resource_requirements_none_safe() -> None:
    """Make moto's _calculate_task_resource_requirements survive None memory.

    AWS lets a Fargate task definition specify cpu/memory at the TASK level
    and omit them per-container. Moto's calculator does

        resource_requirements["MEMORY"] += container_definition.get(
            "memory", container_definition.get("memoryReservation"),
        )

    which evaluates to ``int + None`` when both keys are missing, raising
    ``TypeError: unsupported operand type(s) for +=: 'int' and 'NoneType'``
    and bubbling up as a 500 InternalError on RunTask.

    Idempotent - guarded by a module flag so re-imports / hot-reload do
    not stack the patch.
    """
    try:
        import moto.ecs.models as _m
    except Exception:
        return
    if getattr(_m, "_localemu_resource_req_patched", False):
        return

    def _safe_calc(task_definition):
        req = {"CPU": 0, "MEMORY": 0, "PORTS": [], "PORTS_UDP": []}
        for cdef in task_definition.container_definitions:
            req["CPU"] += cdef.get("cpu", cdef.get("Cpu", 0)) or 0
            mem = (
                cdef.get("Memory")
                or cdef.get("MemoryReservation")
                or cdef.get("memory")
                or cdef.get("memoryReservation")
                or 0
            )
            req["MEMORY"] += int(mem)
            port_key = "PortMappings" if "PortMappings" in cdef else "portMappings"
            for pm in cdef.get(port_key, []) or []:
                host_port = pm.get("hostPort") or pm.get("HostPort")
                proto = (pm.get("protocol") or pm.get("Protocol") or "tcp").lower()
                if host_port:
                    (req["PORTS_UDP"] if proto == "udp" else req["PORTS"]).append(int(host_port))
        return req

    _m.EC2ContainerServiceBackend._calculate_task_resource_requirements = staticmethod(_safe_calc)
    _m._localemu_resource_req_patched = True


def _patch_moto_ec2_memory_reservation_register() -> None:
    """Accept EC2 container defs that set only memoryReservation (#707 / #715).

    Moto's EC2-only branch of ``_validate_container_defs`` requires ``memory``
    (or task-level memory) and ignores ``memoryReservation``. AWS accepts soft
    reservation alone for EC2. The general check already allows it — drop the
    stricter EC2-only gate.
    """
    try:
        import moto.ecs.models as _m
        from moto.ecs.exceptions import TaskDefinitionMemoryError
        from moto.ecs.exceptions import TaskDefinitionMissingPropertyError
    except Exception:
        return
    if getattr(_m, "_localemu_ec2_memres_register_patched", False):
        return

    def _validate_container_defs(memory, container_definitions, requires_compatibilities):
        del requires_compatibilities  # EC2 soft-reservation path matches general rules
        for cd in container_definitions:
            if "name" not in cd and "Name" not in cd:
                raise TaskDefinitionMissingPropertyError("name")
            if "image" not in cd and "Image" not in cd:
                raise TaskDefinitionMissingPropertyError("image")
            if (
                "memory" not in cd
                and "Memory" not in cd
                and "memoryReservation" not in cd
                and "MemoryReservation" not in cd
                and not memory
            ):
                raise TaskDefinitionMemoryError(cd.get("name") or cd.get("Name") or "?")

    _m.EC2ContainerServiceBackend._validate_container_defs = staticmethod(
        _validate_container_defs
    )
    _m._localemu_ec2_memres_register_patched = True


def create_ecs_service() -> Service:
    """Create the ECS service with Docker-aware dispatch table."""
    from localemu.aws.spec import load_service

    _patch_moto_resource_requirements_none_safe()
    _patch_moto_ec2_memory_reservation_register()
    _patch_moto_eni_private_dns_name()
    from localemu.services.ecs.ec2_services import install

    install()
    service_model = load_service("ecs")
    dispatch_table = EcsDispatcher(service_model)
    skeleton = Skeleton(service_model, dispatch_table)
    return Service(name="ecs", skeleton=skeleton, lifecycle_hook=_lifecycle_hook)
