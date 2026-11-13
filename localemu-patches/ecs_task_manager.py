"""Docker Task Manager for ECS tasks.

awsbox patch (#201): secrets ``valueFrom`` via execution role, host-mode
portMappings without Docker PortBindings, and STOPPED + stoppedReason when
containers never start. (#211): ECR image URIs require ``ecr:BatchGetImage``
on the execution role, then pull from the local registry. Mounted over the
LocalEmu image file.

Port mapping TOCTOU is a known limitation. Docker's port allocation
is inherently non-atomic — between get_free_tcp_port() and the actual bind
in container start, another process could claim the port. This is an accepted
trade-off for local emulation; production ECS does not have this issue.
"""

import logging
import os
import shlex
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field

from localemu.utils.container_utils.container_client import (
    BindMount,
    ContainerConfiguration,
    PortMappings,
    Ulimit,
    VolumeMappings,
)
from localemu.utils.docker_utils import DOCKER_CLIENT
from localemu.utils.net import get_free_tcp_port

if "/opt/awsbox/ecr" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/ecr")
import awsbox_ecr_pull as ecr_pull  # noqa: E402

if "/opt/awsbox/tls" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/tls")
import awsbox_gateway_tls as gateway_tls  # noqa: E402

LOG = logging.getLogger(__name__)

# Label for identifying ECS containers
ECS_CONTAINER_LABEL = "localemu.service=ecs"

# Image pull locks (same pattern as Lambda, EC2, and RDS)
# PERF-R2-01: bounded with LRU eviction to prevent unbounded growth
_IMAGE_PULL_LOCKS_MAXSIZE = 64
_image_pull_locks: dict[str, threading.Lock] = {}
_image_pull_locks_lock = threading.Lock()


def _apply_docker_mem_reservation(docker_name: str, mem_reservation: str) -> None:
    """Apply ECS memoryReservation as Docker's soft MemoryReservation (#715).

    ContainerConfiguration has no mem_reservation field; set it after create
    via the SDK (preferred) or ``docker update`` fallback.
    """
    try:
        client_factory = getattr(DOCKER_CLIENT, "client", None)
        if callable(client_factory):
            client_factory().containers.get(docker_name).update(
                mem_reservation=mem_reservation
            )
            return
    except Exception:
        LOG.debug(
            "SDK mem_reservation update failed for %s", docker_name, exc_info=True
        )
    try:
        import subprocess

        subprocess.run(
            [
                "docker",
                "update",
                f"--memory-reservation={mem_reservation}",
                docker_name,
            ],
            check=False,
            capture_output=True,
            timeout=30,
        )
    except Exception:
        LOG.debug(
            "CLI mem_reservation update failed for %s", docker_name, exc_info=True
        )


@dataclass
class EcsContainerInfo:
    """Tracks a single running container within an ECS task."""

    container_name: str
    docker_name: str
    image: str
    host_ports: dict[int, int] = field(default_factory=dict)
    status: str = "PENDING"
    exit_code: int | None = None
    # awsvpc: address on localemu-vpc-* (subnet-pinned when possible)
    private_ipv4: str | None = None


@dataclass
class EcsTaskInfo:
    """Tracks a running ECS task (which may have multiple containers)."""

    task_arn: str
    task_id: str
    cluster_name: str
    task_definition_arn: str
    containers: list[EcsContainerInfo] = field(default_factory=list)
    status: str = "RUNNING"
    # Timing fields
    created_at: float | None = None
    started_at: float | None = None
    stopped_at: float | None = None
    # AWS DescribeTasks field when the task never reached RUNNING
    stopped_reason: str | None = None
    # awsvpc ENI address reported on attachments / networkInterfaces (#268)
    private_ipv4: str | None = None
    subnet_id: str | None = None
    vpc_id: str | None = None
    # SubnetAllocator reservations to release on stop
    reserved_ips: list[str] = field(default_factory=list)


class DockerTaskManager:
    """Manages Docker containers as ECS task instances.

    Each ECS task maps to one or more Docker containers, one per
    containerDefinition in the task definition.
    """

    def __init__(self):
        self._tasks: dict[str, EcsTaskInfo] = {}
        self._lock = threading.Lock()
        self._recover_orphaned_containers()

    def _recover_orphaned_containers(self) -> None:
        """Scan for labeled ECS containers left from a previous run.

        Include stopped containers (``all=True``): with ``PERSISTENCE=1``
        shutdown stops containers without removing them, and the post-load
        reconciler ``docker start``s them. Running-only scans miss those
        and leave moto tasks holding CPU/memory/ports with nothing behind
        them (#716).
        """
        try:
            containers = DOCKER_CLIENT.list_containers(
                filter=["label=localemu.service=ecs"],
                all=True,
            )
            recovered = 0
            for container in containers:
                labels = container.get("labels", {})
                task_arn = labels.get("localemu.task-arn")
                if not task_arn or task_arn in self._tasks:
                    continue
                c_name = labels.get("localemu.container-name", "unknown")
                docker_name = container.get("name", "")
                cluster = labels.get("localemu.cluster", "default")
                task_id = task_arn.split("/")[-1] if "/" in task_arn else task_arn[:12]
                state = container.get("state") or container.get("State") or ""
                if isinstance(state, dict):
                    running = bool(state.get("Running"))
                else:
                    running = str(state).lower() in ("running", "up")
                ci = EcsContainerInfo(
                    container_name=c_name,
                    docker_name=docker_name,
                    image=container.get("image", ""),
                    status="RUNNING" if running else "STOPPED",
                )
                if task_arn not in self._tasks:
                    self._tasks[task_arn] = EcsTaskInfo(
                        task_arn=task_arn,
                        task_id=task_id,
                        cluster_name=cluster,
                        task_definition_arn="",
                        status="RUNNING" if running else "STOPPED",
                    )
                self._tasks[task_arn].containers.append(ci)
                recovered += 1
            if recovered:
                LOG.info("Recovered %d orphaned ECS containers", recovered)
        except Exception as e:
            LOG.debug("Failed to scan for orphaned ECS containers: %s", e)

    def _container_name(
        self, cluster: str, task_id: str, container_name: str
    ) -> str:
        """Generate a Docker container name for an ECS task container.

        Format: localemu-ecs-{cluster_short}-{task_id_prefix}-{container_name}

        Use 12-char prefix instead of 8 to reduce collision probability.
        """
        cluster_short = cluster.split("/")[-1] if "/" in cluster else cluster
        # Truncate cluster name to keep Docker name reasonable
        cluster_short = cluster_short[:20]
        return f"localemu-ecs-{cluster_short}-{task_id[:12]}-{container_name}"

    def _ensure_image(self, image: str) -> None:
        """Pull Docker image if not available. Thread-safe."""
        with _image_pull_locks_lock:
            if image not in _image_pull_locks:
                # PERF-R2-01: evict oldest entry when maxsize reached
                if len(_image_pull_locks) >= _IMAGE_PULL_LOCKS_MAXSIZE:
                    oldest_key = next(iter(_image_pull_locks))
                    del _image_pull_locks[oldest_key]
                _image_pull_locks[image] = threading.Lock()
            lock = _image_pull_locks[image]

        with lock:
            try:
                DOCKER_CLIENT.inspect_image(image)
            except Exception:
                LOG.info("Pulling ECS task image %s...", image)
                try:
                    DOCKER_CLIENT.pull_image(image)
                    LOG.info("Image %s pulled successfully", image)
                except Exception as e:
                    raise RuntimeError(
                        f"Failed to pull ECS task image {image}: {e}"
                    ) from e

    @staticmethod
    def _parse_secret_value_from(value_from: str) -> dict:
        """Parse ECS ``secrets[].valueFrom`` into a fetch plan.

        Supports Secrets Manager ARNs (optional ``:json-key:stage:version``),
        SSM parameter ARNs, and bare SSM parameter names/paths.
        """
        vf = (value_from or "").strip()
        if not vf:
            raise ValueError("empty valueFrom")

        if ":secretsmanager:" in vf and ":secret:" in vf:
            # arn:…:secret:name[-suffix][:json-key[:stage[:version]]]
            head, rest = vf.split(":secret:", 1)
            parts = rest.split(":")
            secret_name = parts[0]
            secret_arn = f"{head}:secret:{secret_name}"
            json_key = parts[1] if len(parts) > 1 and parts[1] != "" else None
            version_stage = parts[2] if len(parts) > 2 and parts[2] != "" else None
            version_id = parts[3] if len(parts) > 3 and parts[3] != "" else None
            return {
                "service": "secretsmanager",
                "secret_id": secret_arn,
                "json_key": json_key,
                "version_stage": version_stage,
                "version_id": version_id,
            }

        if ":ssm:" in vf and ":parameter" in vf:
            # arn:aws:ssm:region:account:parameter/name
            idx = vf.find(":parameter")
            param = vf[idx + len(":parameter") :]
            if param.startswith("/"):
                name = param
            else:
                name = "/" + param.lstrip("/")
            return {"service": "ssm", "name": name}

        # Bare SSM name / path
        return {"service": "ssm", "name": vf}

    def _execution_role_boto_kwargs(
        self,
        *,
        execution_role_arn: str,
        region: str,
        account_id: str,
        task_id: str,
    ) -> dict:
        """Boto3 kwargs signed as the execution role via the gateway."""
        return ecr_pull.role_boto_kwargs(
            role_arn=execution_role_arn,
            region=region,
            account_id=account_id,
            session_name=f"ecs-execute-{task_id[:32]}",
        )

    def _execution_role_clients(
        self,
        *,
        execution_role_arn: str,
        region: str,
        account_id: str,
        task_id: str,
    ):
        import boto3

        common = self._execution_role_boto_kwargs(
            execution_role_arn=execution_role_arn,
            region=region,
            account_id=account_id,
            task_id=task_id,
        )
        return (
            boto3.client("secretsmanager", **common),
            boto3.client("ssm", **common),
        )

    def _resolve_ecr_image(
        self,
        image: str,
        *,
        execution_role_arn: str | None,
        region: str,
        account_id: str,
        task_id: str,
    ) -> str:
        """Map an ECR image URI to the local registry after BatchGetImage."""
        local = ecr_pull.resolve_ecr_image(
            image,
            role_arn=execution_role_arn,
            region=region,
            account_id=account_id,
            session_name=f"ecs-execute-{task_id[:32]}",
            role_label="execution role",
        )
        if local != image:
            LOG.info(
                "ECS task %s pulling ECR image %s as %s",
                task_id[:12],
                image,
                local,
            )
        return local

    def _resolve_container_secrets(
        self,
        secrets: list,
        *,
        execution_role_arn: str | None,
        region: str,
        account_id: str,
        task_id: str,
    ) -> dict[str, str]:
        """Resolve ``containerDefinitions[].secrets`` via the task execution role.

        Mirrors AWS: agent fetches with the execution role before start; failure
        becomes ``ResourceInitializationError`` and the task does not start.
        """
        if not secrets:
            return {}

        if not execution_role_arn:
            raise RuntimeError(
                "ResourceInitializationError: unable to pull secrets or registry "
                "auth: execution role is not specified for secrets injection"
            )

        try:
            sm_client, ssm_client = self._execution_role_clients(
                execution_role_arn=execution_role_arn,
                region=region,
                account_id=account_id,
                task_id=task_id,
            )
        except Exception as e:
            raise RuntimeError(
                "ResourceInitializationError: unable to pull secrets or registry "
                f"auth: failed to assume execution role {execution_role_arn}: {e}"
            ) from e

        resolved: dict[str, str] = {}
        for entry in secrets:
            if not isinstance(entry, dict):
                continue
            name = entry.get("name") or entry.get("Name")
            value_from = entry.get("valueFrom") or entry.get("value_from")
            if not name or not value_from:
                continue
            try:
                plan = self._parse_secret_value_from(str(value_from))
                if plan["service"] == "secretsmanager":
                    kwargs: dict = {"SecretId": plan["secret_id"]}
                    if plan.get("version_id"):
                        kwargs["VersionId"] = plan["version_id"]
                    if plan.get("version_stage"):
                        kwargs["VersionStage"] = plan["version_stage"]
                    resp = sm_client.get_secret_value(**kwargs)
                    raw = resp.get("SecretString")
                    if raw is None and resp.get("SecretBinary") is not None:
                        import base64

                        raw = base64.b64decode(resp["SecretBinary"]).decode(
                            "utf-8", errors="replace"
                        )
                    if raw is None:
                        raise RuntimeError("secret has no SecretString/SecretBinary")
                    json_key = plan.get("json_key")
                    if json_key:
                        import json

                        data = json.loads(raw)
                        if json_key not in data:
                            raise RuntimeError(
                                f"json-key {json_key!r} not found in secret"
                            )
                        raw = data[json_key]
                        if not isinstance(raw, str):
                            raw = str(raw)
                    resolved[name] = raw
                else:
                    resp = ssm_client.get_parameter(
                        Name=plan["name"], WithDecryption=True
                    )
                    resolved[name] = resp["Parameter"]["Value"]
            except Exception as e:
                raise RuntimeError(
                    "ResourceInitializationError: unable to pull secrets or "
                    f"registry auth: unable to retrieve secret {value_from}: {e}"
                ) from e

        LOG.info(
            "Resolved %d ECS secret(s) for task %s via execution role",
            len(resolved),
            task_id[:12],
        )
        return resolved

    def _finalize_task_status(self, task_info: "EcsTaskInfo") -> None:
        """Mark the task STOPPED when no container reached RUNNING (#201)."""
        running = [c for c in task_info.containers if c.status == "RUNNING"]
        if running:
            task_info.status = "RUNNING"
            if not task_info.started_at:
                task_info.started_at = time.time()
            return
        task_info.status = "STOPPED"
        if not task_info.stopped_at:
            task_info.stopped_at = time.time()
        if not task_info.stopped_reason:
            if not task_info.containers:
                task_info.stopped_reason = (
                    "Essential container in task exited before it started"
                )
            else:
                task_info.stopped_reason = (
                    "CannotStartContainerError: container failed to start"
                )

    def run_task(
        self,
        cluster_name: str,
        task_definition: dict,
        task_arn: str,
        count: int = 1,
        overrides: dict | None = None,
        launch_type: str = "EC2",
        region: str = "us-east-1",
        network_configuration: dict | None = None,
        account_id: str = "",
    ) -> list[EcsTaskInfo]:
        """Start Docker containers for an ECS RunTask call.

        Args:
            cluster_name: ECS cluster name or ARN.
            task_definition: The resolved task definition dict containing
                containerDefinitions and other metadata.
            task_arn: The task ARN assigned by Moto.
            count: Number of task copies to launch.
            overrides: Optional container overrides from the RunTask request.
            launch_type: EC2 or FARGATE.
            Region: AWS region for env vars .

        Returns:
            List of EcsTaskInfo with container details.
        """
        container_defs = task_definition.get("containerDefinitions") or task_definition.get("container_definitions") or []
        if not container_defs:
            LOG.warning("Task definition has no containerDefinitions, skipping Docker launch")
            return []

        container_overrides = {}
        if overrides and overrides.get("containerOverrides"):
            for co in overrides["containerOverrides"]:
                name = co.get("name")
                if name:
                    container_overrides[name] = co

        # Extract network mode from task definition
        network_mode = task_definition.get("networkMode", "bridge")

        # Task role for IAM — RunTask's ``overrides.taskRoleArn`` wins over
        # the task definition's ``taskRoleArn`` (AWS API semantics).
        task_role_arn = (overrides or {}).get("taskRoleArn") or task_definition.get(
            "taskRoleArn"
        )
        # Execution role fetches secrets / image pull auth before start.
        execution_role_arn = (overrides or {}).get(
            "executionRoleArn"
        ) or task_definition.get("executionRoleArn")

        # Extract volume definitions for mounting
        td_volumes = task_definition.get("volumes", [])
        # Build a map of volume name -> host path or Docker volume name
        volume_map: dict[str, str] = {}
        for vol in td_volumes:
            vol_name = vol.get("name", "") if isinstance(vol, dict) else ""
            if not vol_name:
                continue
            host = vol.get("host", {}) if isinstance(vol, dict) else {}
            if isinstance(host, dict) and host.get("sourcePath"):
                volume_map[vol_name] = host["sourcePath"]
            else:
                # Use a Docker named volume
                volume_map[vol_name] = vol_name

        results: list[EcsTaskInfo] = []

        for i in range(count):
            # Generate unique task ID for each count iteration
            # When count > 1, Moto creates one task ARN but we need unique IDs
            if i == 0:
                task_id = task_arn.split("/")[-1] if "/" in task_arn else str(uuid.uuid4())
                effective_arn = task_arn
            else:
                task_id = str(uuid.uuid4())
                # Build a unique ARN for each additional copy
                arn_prefix = "/".join(task_arn.split("/")[:-1]) if "/" in task_arn else task_arn
                effective_arn = f"{arn_prefix}/{task_id}"

            task_info = EcsTaskInfo(
                task_arn=effective_arn,
                task_id=task_id,
                cluster_name=cluster_name,
                task_definition_arn=task_definition.get("taskDefinitionArn", ""),
                # Track creation time
                created_at=time.time(),
            )

            for cdef in container_defs:
                c_name = cdef.get("name", "container")
                image = cdef.get("image", "")

                if not image:
                    LOG.warning(
                        "ECS container %s has no image, skipping", c_name
                    )
                    continue

                # Apply overrides
                co = container_overrides.get(c_name, {})
                if co.get("command"):
                    command = co["command"]
                elif cdef.get("command"):
                    command = cdef["command"]
                else:
                    command = None

                # Use shlex.split() for string commands
                if command and isinstance(command, str):
                    command = shlex.split(command)
                elif command and isinstance(command, list):
                    pass  # already a list, keep as-is
                else:
                    command = None

                # #685: task-def entryPoint overrides the image ENTRYPOINT
                # (docker --entrypoint). ContainerOverride has no entryPoint.
                raw_ep = cdef.get("entryPoint") or cdef.get("entry_point")
                if raw_ep and isinstance(raw_ep, str):
                    entrypoint: list[str] | str | None = shlex.split(raw_ep)
                elif raw_ep and isinstance(raw_ep, list):
                    entrypoint = raw_ep
                else:
                    entrypoint = None

                # Build environment variables
                env_vars: dict[str, str] = {}
                for env in cdef.get("environment", []):
                    env_vars[env.get("name", "")] = env.get("value", "")
                # Apply environment overrides
                for env in co.get("environment", []):
                    env_vars[env.get("name", "")] = env.get("value", "")

                # #201: secrets valueFrom via execution role (before start)
                try:
                    secret_env = self._resolve_container_secrets(
                        cdef.get("secrets") or [],
                        execution_role_arn=execution_role_arn,
                        region=region,
                        account_id=account_id,
                        task_id=task_id,
                    )
                    env_vars.update(secret_env)
                except Exception as e:
                    reason = str(e)
                    if not reason.startswith("ResourceInitializationError"):
                        reason = f"ResourceInitializationError: {reason}"
                    LOG.warning(
                        "ECS secrets resolution failed for task %s container %s: %s",
                        task_id[:12],
                        c_name,
                        reason,
                    )
                    task_info.stopped_reason = reason
                    task_info.status = "STOPPED"
                    task_info.stopped_at = time.time()
                    container_info = EcsContainerInfo(
                        container_name=c_name,
                        docker_name=self._container_name(
                            cluster_name, task_id, c_name
                        ),
                        image=image,
                        status="STOPPED",
                        exit_code=1,
                    )
                    task_info.containers.append(container_info)
                    # Remaining containers in this task are not started
                    break

                # Add LocalEmu metadata
                env_vars["LOCALEMU_ECS_TASK_ARN"] = effective_arn
                env_vars["LOCALEMU_ECS_CLUSTER"] = cluster_name
                env_vars["LOCALEMU_ECS_CONTAINER_NAME"] = c_name

                # #79/#154: Standard ECS env vars. Creds listen inside
                # LocalEmu; non-host tasks DNAT 169.254.170.2:80 → this
                # container's compose-network IP:creds_port after start
                # (SDKs only trust link-local / loopback for the creds
                # URI). Sidecar covers images without iptables.
                from localemu import config as _le_config
                from localemu.services.ecs.docker.task_credentials import (
                    get_task_credentials_server,
                )
                _creds_server = get_task_credentials_server()
                _creds_port = _creds_server.port
                _gw_port = _le_config.GATEWAY_LISTEN[0].port

                env_vars["ECS_CONTAINER_METADATA_URI"] = (
                    f"http://169.254.170.2/v3/{task_id}"
                )
                env_vars["ECS_CONTAINER_METADATA_URI_V4"] = (
                    f"http://169.254.170.2/v4/{task_id}"
                )
                env_vars["AWS_DEFAULT_REGION"] = region
                env_vars["AWS_REGION"] = region
                # #269: host.docker.internal → bridge gateway, but compose
                # publishes :4566 on 127.0.0.1 only. Point at this LocalEmu
                # container's docker-network IP (same idea as EC2 IMDS) and
                # attach the task to that network after start.
                # #687: https + trusted CA so aws:SecureTransport matches AWS
                # (TLS-only bucket policies must not deny task-role calls).
                _gw_host, _gw_net = self._emulator_endpoint_target(network_mode)
                _endpoint_host = self._emulator_tls_endpoint_host(
                    network_mode, _gw_host
                )
                env_vars["AWS_ENDPOINT_URL"] = (
                    f"https://{_endpoint_host}:{_gw_port}"
                )
                self._append_no_proxy(env_vars, _endpoint_host)
                if _gw_host != _endpoint_host:
                    self._append_no_proxy(env_vars, _gw_host)
                if task_role_arn:
                    if network_mode == "host":
                        # Host mode shares the host netns: no DNAT (it would land in
                        # the host's NAT table). Loopback is SDK-approved; the creds
                        # port is published on host 127.0.0.1 (start.d/05-ecs-creds-port.py).
                        env_vars["AWS_CONTAINER_CREDENTIALS_FULL_URI"] = (
                            f"http://127.0.0.1:{_creds_port}/v2/credentials/{task_id}"
                        )
                    else:
                        # RELATIVE_URI resolves against 169.254.170.2 (one of
                        # the SDK's four approved hosts). DNAT does the rest.
                        env_vars["AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"] = (
                            f"/v2/credentials/{task_id}"
                        )
                    # Mint STS creds via moto's backend; the assumed_role
                    # entry it creates lets our IAM enforcer resolve the
                    # signed request back to the correct role.
                    try:
                        from datetime import datetime, timedelta, timezone
                        from moto.sts.models import sts_backends
                        sts_backend = sts_backends[account_id or "000000000000"]["global"]
                        assumed = sts_backend.assume_role(
                            region_name=region,
                            role_session_name=f"ecs-task-{task_id[:32]}",
                            role_arn=task_role_arn,
                            policy=None,
                            duration=3600,
                            external_id=None,
                        )
                        _creds_server.store.put(task_id, {
                            "RoleArn": task_role_arn,
                            "AccessKeyId": assumed.access_key_id,
                            "SecretAccessKey": assumed.secret_access_key,
                            "Token": assumed.session_token,
                            "Expiration": (
                                datetime.now(timezone.utc) + timedelta(hours=1)
                            ).isoformat().replace("+00:00", "Z"),
                        })
                        LOG.info(
                            "Generated task-role credentials for ECS task %s "
                            "(role=%s, key=%s***)",
                            task_id, task_role_arn,
                            assumed.access_key_id[:4],
                        )
                    except Exception as e:
                        LOG.error(
                            "Failed to mint task-role credentials for ECS task %s "
                            "(role=%s): %s — SDKs inside the container will see "
                            "NoCredentialsError",
                            task_id, task_role_arn, e, exc_info=True,
                        )
                        # Drop the relative URI so the SDK fails at
                        # credential discovery rather than hitting an
                        # empty endpoint.
                        env_vars.pop(
                            "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", None,
                        )
                        env_vars.pop("AWS_CONTAINER_CREDENTIALS_FULL_URI", None)

                # Build port mappings. AWS accepts portMappings with
                # networkMode=host when hostPort==containerPort (or omitted);
                # Docker rejects HostConfig.PortBindings in host mode, so we
                # record the ports for DescribeTasks but do not bind (#201).
                ports = PortMappings()
                host_ports: dict[int, int] = {}
                for pm in cdef.get("portMappings", []):
                    container_port = pm.get("containerPort")
                    if not container_port:
                        continue
                    if network_mode == "host":
                        host_port = pm.get("hostPort") or container_port
                        host_ports[container_port] = host_port
                    else:
                        host_port = pm.get("hostPort") or get_free_tcp_port()
                        ports.add(host_port, container_port)
                        host_ports[container_port] = host_port

                docker_image = image
                try:
                    docker_image = self._resolve_ecr_image(
                        image,
                        execution_role_arn=execution_role_arn,
                        region=region,
                        account_id=account_id,
                        task_id=task_id,
                    )
                except Exception as e:
                    reason = str(e)
                    if "CannotPullContainerError" not in reason and not reason.startswith(
                        "ResourceInitializationError"
                    ):
                        reason = f"CannotPullContainerError: {reason}"
                    LOG.warning(
                        "ECS image auth failed for task %s container %s: %s",
                        task_id[:12],
                        c_name,
                        reason,
                    )
                    task_info.stopped_reason = reason
                    task_info.status = "STOPPED"
                    task_info.stopped_at = time.time()
                    task_info.containers.append(
                        EcsContainerInfo(
                            container_name=c_name,
                            docker_name=self._container_name(
                                cluster_name, task_id, c_name
                            ),
                            image=image,
                            status="STOPPED",
                            exit_code=1,
                        )
                    )
                    break

                # Ensure image is available
                try:
                    self._ensure_image(docker_image)
                except Exception as e:
                    LOG.warning(
                        "Failed to pull image %s for ECS task %s: %s",
                        docker_image, task_id, e,
                    )
                    task_info.stopped_reason = (
                        f"CannotPullContainerError: {e}"
                    )
                    container_info = EcsContainerInfo(
                        container_name=c_name,
                        docker_name=self._container_name(
                            cluster_name, task_id, c_name
                        ),
                        image=image,
                        status="STOPPED",
                        exit_code=1,
                    )
                    task_info.containers.append(container_info)
                    continue

                docker_name = self._container_name(cluster_name, task_id, c_name)

                # Build volume mappings from mountPoints
                volumes = VolumeMappings()
                for mp in cdef.get("mountPoints", []):
                    if isinstance(mp, dict):
                        src_vol = mp.get("sourceVolume", "")
                        container_path = mp.get("containerPath", "")
                        if src_vol and container_path and src_vol in volume_map:
                            host_path = volume_map[src_vol]
                            read_only = mp.get("readOnly", False)
                            # Use BindMount so the read-only flag is honored
                            # by the Docker SDK. The legacy tuple form ignored the mode.
                            volumes.append(
                                BindMount(host_path, container_path, read_only=read_only)
                            )
                # #687: trust the LocalEmu gateway CA (AWS_CA_BUNDLE / Node / curl).
                try:
                    gateway_tls.inject_task_tls_trust(env_vars, volumes)
                except Exception:
                    LOG.warning(
                        "could not inject gateway CA into ECS task env",
                        exc_info=True,
                    )

                # Determine Docker network mode
                docker_network = None
                awsvpc_gateway = None
                if network_mode == "host":
                    docker_network = "host"
                elif network_mode == "none":
                    docker_network = "none"
                elif network_mode == "awsvpc":
                    # Create on the VPC bridge only (#271). Default docker
                    # bridge left a 172.17.0.0/16 on-link route to the host.
                    # Docker refuses further connects when created with
                    # network "none", so we join VPC at create and re-pin
                    # inside the subnet in _connect_to_vpc_network (#360).
                    awsvpc_cfg_early = (network_configuration or {}).get(
                        "awsvpcConfiguration"
                    ) or {}
                    docker_network, awsvpc_gateway = self._resolve_awsvpc_network(
                        awsvpc_cfg_early.get("subnets") or [],
                        account_id,
                        region,
                    )
                    if not docker_network:
                        docker_network = "none"

                # Extract CPU/memory limits from container definition.
                # AWS: memory = hard Docker mem_limit; memoryReservation = soft
                # mem_reservation (placement + cgroup soft). Do not promote soft
                # to hard — that OOM-kills bursts that survive on real ECS (#715).
                cpu_shares = None
                mem_limit = None
                mem_reservation = None
                container_cpu = cdef.get("cpu")
                hard_memory = cdef.get("memory")
                soft_memory = cdef.get("memoryReservation")
                if container_cpu:
                    # ECS cpu units map to Docker cpu_shares (1024 = 1 vCPU)
                    try:
                        cpu_shares = int(container_cpu)
                    except (ValueError, TypeError):
                        pass
                # ECS memory values are MiB
                if hard_memory:
                    try:
                        mem_limit = f"{int(hard_memory)}m"
                    except (ValueError, TypeError):
                        pass
                if soft_memory:
                    try:
                        mem_reservation = f"{int(soft_memory)}m"
                    except (ValueError, TypeError):
                        pass

                # Build Docker health check flags from task definition.
                # ECS accepts ["CMD", "exit 0"] or ["CMD-SHELL", "exit 0"] per
                # RegisterTaskDefinition's ``containerDefinitions.healthCheck``
                # contract; we translate both to ``docker create --health-*``
                # CLI flags via ``ContainerConfiguration.additional_flags`` so
                # the resulting container actually has a Healthcheck set, which
                # is what the user observes via ``docker inspect`` and what ECS
                # uses to decide task health. Before this, the command was
                # parsed but discarded — the container started with no health
                # check, making services relying on health never stabilize.
                additional_flags_parts: list[str] = []
                hc = cdef.get("healthCheck")
                if hc and isinstance(hc, dict):
                    hc_command = hc.get("command", [])
                    if isinstance(hc_command, list) and len(hc_command) >= 2:
                        if hc_command[0] == "CMD-SHELL":
                            hc_shell = hc_command[1]
                            additional_flags_parts.append(
                                f"--health-cmd={shlex.quote(hc_shell)}"
                            )
                        elif hc_command[0] == "CMD":
                            # Docker CLI --health-cmd runs through a shell,
                            # so join argv tokens the same way real ECS does.
                            hc_shell = " ".join(shlex.quote(p) for p in hc_command[1:])
                            additional_flags_parts.append(
                                f"--health-cmd={shlex.quote(hc_shell)}"
                            )
                    interval = hc.get("interval")
                    if interval:
                        additional_flags_parts.append(f"--health-interval={int(interval)}s")
                    timeout_s = hc.get("timeout")
                    if timeout_s:
                        additional_flags_parts.append(f"--health-timeout={int(timeout_s)}s")
                    retries = hc.get("retries")
                    if retries:
                        additional_flags_parts.append(f"--health-retries={int(retries)}")
                    start_period = hc.get("startPeriod") or hc.get("start_period")
                    if start_period:
                        additional_flags_parts.append(
                            f"--health-start-period={int(start_period)}s"
                        )
                # #79: Always add host.docker.internal mapping so the task's
                # SDK can reach both the host-bound credentials server and
                # the LocalEmu gateway. On Docker Desktop this is a no-op
                # (the DNS name resolves automatically); on Linux + Docker
                # CE it's required.
                if network_mode == "awsvpc" and awsvpc_gateway:
                    additional_flags_parts.append(
                        f"--add-host host.docker.internal:{awsvpc_gateway}"
                    )
                else:
                    additional_flags_parts.append(
                        "--add-host host.docker.internal:host-gateway"
                    )
                # #459: SDK v3 uses QueueUrl host (sqs.<region>.localhost); map
                # it to the same LocalEmu address AWS_ENDPOINT_URL already uses
                # (_gw_host). Docker --add-host requires an IP — skip when
                # _emulator_endpoint_target fell back to host.docker.internal.
                try:
                    import ipaddress as _ipaddress

                    _ipaddress.ip_address(_gw_host)
                    _sqs_add_host_ok = True
                except ValueError:
                    _sqs_add_host_ok = False
                if _sqs_add_host_ok:
                    _emu_dns = (
                        getattr(_le_config.LOCALEMU_HOST, "host", None) or "localhost"
                    )
                    additional_flags_parts.append(
                        f"--add-host sqs.{region}.{_emu_dns}:{_gw_host}"
                    )
                    # #687: AWS_ENDPOINT_URL uses localemu.awsbox (cert SAN).
                    additional_flags_parts.append(
                        f"--add-host {gateway_tls.EMU_DNS_NAME}:{_gw_host}"
                    )
                if network_mode == "awsvpc":
                    awsvpc_cfg = (network_configuration or {}).get(
                        "awsvpcConfiguration"
                    ) or {}
                    dns_ip = self._private_dns_ip(
                        awsvpc_cfg.get("subnets") or [],
                        account_id,
                        region,
                    )
                    if dns_ip:
                        additional_flags_parts.append(f"--dns {dns_ip}")
                # #711: readonlyRootFilesystem is not mapped — LocalEmu
                # parse_additional_flags rejects --read-only, and
                # ContainerConfiguration has no rootfs read_only field.
                additional_flags = " ".join(additional_flags_parts) if additional_flags_parts else None

                # #711: containerDefinitions.user (uid / uid:gid / name / name:group)
                container_user = cdef.get("user")
                if container_user is not None:
                    container_user = str(container_user).strip() or None

                container_ulimits: list[Ulimit] | None = None
                raw_ulimits = cdef.get("ulimits")
                if isinstance(raw_ulimits, list) and raw_ulimits:
                    parsed_ulimits: list[Ulimit] = []
                    for u in raw_ulimits:
                        if not isinstance(u, dict):
                            continue
                        name = u.get("name")
                        soft = u.get("softLimit", u.get("soft"))
                        hard = u.get("hardLimit", u.get("hard"))
                        if name is None or soft is None:
                            continue
                        try:
                            soft_i = int(soft)
                            hard_i = int(hard) if hard is not None else None
                        except (TypeError, ValueError):
                            continue
                        parsed_ulimits.append(
                            Ulimit(
                                name=str(name),
                                soft_limit=soft_i,
                                hard_limit=hard_i,
                            )
                        )
                    if parsed_ulimits:
                        container_ulimits = parsed_ulimits

                # User dockerLabels first; reserved localemu.* always win
                # so task-role reminting (#79) and filters stay intact.
                container_labels: dict[str, str] = {}
                docker_labels = cdef.get("dockerLabels")
                if isinstance(docker_labels, dict):
                    for dk, dv in docker_labels.items():
                        container_labels[str(dk)] = str(dv)
                container_labels.update({
                    "localemu.service": "ecs",
                    "localemu.cluster": cluster_name,
                    "localemu.task-arn": effective_arn,
                    "localemu.container-name": c_name,
                    "localemu.network-mode": network_mode,
                    # #79: task-role is persisted on the container so
                    # the on-load reconciler can re-mint creds.
                    "localemu.task-role-arn": task_role_arn or "",
                })

                workdir = cdef.get("workingDirectory") or None
                if workdir is not None:
                    workdir = str(workdir).strip() or None

                # Container config
                container_config = ContainerConfiguration(
                    image_name=docker_image,
                    name=docker_name,
                    env_vars=env_vars,
                    ports=ports,
                    volumes=volumes,
                    command=command if isinstance(command, list) else (
                        [command] if command else None
                    ),
                    entrypoint=entrypoint,
                    detach=True,
                    network=docker_network,
                    cpu_shares=cpu_shares,
                    mem_limit=mem_limit,
                    additional_flags=additional_flags,
                    user=container_user,
                    privileged=bool(cdef.get("privileged")),
                    ulimits=container_ulimits,
                    workdir=workdir,
                    # #79/#154: NET_ADMIN for in-netns DNAT when the image
                    # has iptables; otherwise vpc_routing's alpine sidecar
                    # programs the same rule. SDKs require 169.254.170.2
                    # (not host.docker.internal) for the creds URI.
                    cap_add=["NET_ADMIN"],
                    labels=container_labels,
                )

                LOG.info(
                    "Starting ECS container %s (image=%s, task=%s)",
                    docker_name, image, task_id[:12],
                )

                try:
                    DOCKER_CLIENT.create_container_from_config(container_config)
                    if mem_reservation:
                        _apply_docker_mem_reservation(docker_name, mem_reservation)
                    try:
                        DOCKER_CLIENT.start_container(docker_name)
                    except Exception as start_err:
                        # Container start failure — remove the created container
                        LOG.warning(
                            "Failed to start ECS container %s, removing: %s",
                            docker_name, start_err,
                        )
                        try:
                            DOCKER_CLIENT.remove_container(docker_name)
                        except Exception:
                            pass
                        if not task_info.stopped_reason:
                            task_info.stopped_reason = (
                                f"CannotStartContainerError: {start_err}"
                            )
                        container_info = EcsContainerInfo(
                            container_name=c_name,
                            docker_name=docker_name,
                            image=image,
                            host_ports=host_ports,
                            status="STOPPED",
                            exit_code=1,
                        )
                        task_info.containers.append(container_info)
                        continue

                    # #269: join LocalEmu's network *before* VPC route sync so
                    # the compose-network default route is stripped with the
                    # rest (private subnet must not gain egress via eth2).
                    if network_mode != "host" and _gw_net:
                        self._connect_to_emulator_network(docker_name, _gw_net)

                    # Connect to the VPC network derived
                    # from the task's awsvpcConfiguration.subnets.
                    # Bridge tasks use the container-instance subnet (#230).
                    private_ipv4 = None
                    if network_mode == "awsvpc":
                        awsvpc_cfg = (network_configuration or {}).get(
                            "awsvpcConfiguration", {},
                        )
                        subnet_ids = awsvpc_cfg.get("subnets") or []
                        sg_ids = list(awsvpc_cfg.get("securityGroups") or [])
                        private_ipv4 = self._connect_to_vpc_network(
                            docker_name, cluster_name,
                            subnet_ids=subnet_ids,
                            account_id=account_id,
                            region=region,
                            task_info=task_info,
                        )
                        self._use_private_resolv(
                            docker_name, subnet_ids, account_id, region,
                        )
                        self._attach_awsvpc_sg(
                            docker_name, subnet_ids, sg_ids, account_id, region,
                        )
                    elif network_mode == "bridge":
                        bridge_subnets = self._bridge_subnet_ids(
                            cluster_name,
                            network_configuration,
                            account_id,
                            region,
                        )
                        if bridge_subnets:
                            private_ipv4 = self._connect_bridge_to_vpc(
                                docker_name,
                                subnet_ids=bridge_subnets,
                                account_id=account_id,
                                region=region,
                                task_info=task_info,
                            )

                    # #79/#154: DNAT 169.254.170.2:80 → LocalEmu compose IP
                    # (same host as AWS_ENDPOINT_URL). Not host.docker.internal:
                    # compose publishes the creds port on 127.0.0.1 only.
                    if task_role_arn and network_mode != "host":
                        self._install_task_creds_dnat(
                            docker_name, _creds_port, _gw_host,
                        )

                    container_info = EcsContainerInfo(
                        container_name=c_name,
                        docker_name=docker_name,
                        image=image,
                        host_ports=host_ports,
                        status="RUNNING",
                        private_ipv4=private_ipv4,
                    )
                    task_info.containers.append(container_info)
                    if private_ipv4 and not task_info.private_ipv4:
                        task_info.private_ipv4 = private_ipv4

                    # Track started time
                    task_info.started_at = time.time()

                    port_info = (
                        f", ports={host_ports}" if host_ports else ""
                    )
                    LOG.info(
                        "ECS container %s running (image=%s%s)",
                        docker_name, image, port_info,
                    )
                except Exception as e:
                    LOG.warning(
                        "Failed to create ECS container %s: %s",
                        docker_name, e,
                    )
                    if not task_info.stopped_reason:
                        task_info.stopped_reason = (
                            f"CannotStartContainerError: {e}"
                        )
                    container_info = EcsContainerInfo(
                        container_name=c_name,
                        docker_name=docker_name,
                        image=image,
                        host_ports=host_ports,
                        status="STOPPED",
                        exit_code=1,
                    )
                    task_info.containers.append(container_info)

            self._finalize_task_status(task_info)

            with self._lock:
                self._tasks[effective_arn] = task_info

            results.append(task_info)

        return results

    def _private_dns_ip(
        self,
        subnet_ids: list[str] | None,
        account_id: str,
        region: str,
    ) -> str | None:
        if not subnet_ids:
            return None
        try:
            from localemu.services.ec2.docker.vpce_private_dns import (
                dns_server_ip_for_subnet,
            )
        except Exception:
            LOG.debug("VPCE private DNS helper unavailable", exc_info=True)
            return None
        for subnet_id in subnet_ids:
            try:
                ip = dns_server_ip_for_subnet(subnet_id, account_id, region)
            except Exception:
                LOG.warning(
                    "VPCE private DNS address lookup failed for %s",
                    subnet_id,
                    exc_info=True,
                )
                ip = None
            if ip:
                return ip
        return None

    def _use_private_resolv(
        self,
        docker_name: str,
        subnet_ids: list[str] | None,
        account_id: str,
        region: str,
    ) -> None:
        dns_ip = self._private_dns_ip(subnet_ids, account_id, region)
        if not dns_ip:
            return
        try:
            DOCKER_CLIENT.exec_in_container(
                docker_name,
                ["sh", "-c", f"printf 'nameserver {dns_ip}\\n' > /etc/resolv.conf"],
            )
        except Exception:
            LOG.warning(
                "could not point %s resolv.conf at %s",
                docker_name,
                dns_ip,
                exc_info=True,
            )

    @staticmethod
    def _append_no_proxy(env_vars: dict[str, str], host: str) -> None:
        """Ensure SDKs/tools skip HTTP(S)_PROXY for the emulator host (#269)."""
        if not host:
            return
        for key in ("NO_PROXY", "no_proxy"):
            existing = env_vars.get(key, "")
            parts = [p.strip() for p in existing.split(",") if p.strip()]
            if host not in parts:
                parts.append(host)
            env_vars[key] = ",".join(parts)

    @staticmethod
    def _emulator_endpoint_target(network_mode: str) -> tuple[str, str | None]:
        """Host (or IP) for AWS_ENDPOINT_URL and optional docker network to join.

        Host-network tasks use loopback (compose publishes on 127.0.0.1).
        Other modes prefer this LocalEmu container's address on its compose
        network so tasks do not depend on the loopback-only host publish.
        """
        if network_mode == "host":
            return "127.0.0.1", None
        try:
            from localemu.services.ec2.docker.vpc_endpoint import _localemu_gateway

            ip, net = _localemu_gateway()
        except Exception:
            LOG.debug("emulator gateway lookup failed", exc_info=True)
            ip, net = None, None
        if ip:
            return ip, net if net and net != "bridge" else None
        return "host.docker.internal", None

    @staticmethod
    def _emulator_tls_endpoint_host(network_mode: str, gw_host: str) -> str:
        """Hostname used in ``https://`` ``AWS_ENDPOINT_URL`` (#687).

        Non-host tasks dial ``localemu.awsbox`` (cert SAN + ``--add-host``).
        Host-network tasks keep loopback (SAN includes 127.0.0.1).
        """
        if network_mode == "host" or gw_host in ("127.0.0.1", "localhost"):
            return "127.0.0.1"
        try:
            import ipaddress as _ipaddress

            _ipaddress.ip_address(gw_host)
            return gateway_tls.EMU_DNS_NAME
        except ValueError:
            return gw_host

    def _connect_to_emulator_network(self, docker_name: str, network: str) -> None:
        """Attach the task to LocalEmu's docker network for AWS_ENDPOINT_URL (#269)."""
        try:
            networks = DOCKER_CLIENT.get_networks(docker_name)
            if network in networks:
                return
            DOCKER_CLIENT.connect_container_to_network(network, docker_name)
            LOG.info(
                "ECS container %s connected to emulator network %s",
                docker_name,
                network,
            )
        except Exception:
            LOG.warning(
                "could not attach %s to emulator network %s",
                docker_name,
                network,
                exc_info=True,
            )

    def _install_task_creds_dnat(
        self, docker_name: str, creds_port: int, creds_host: str,
    ) -> None:
        """DNAT 169.254.170.2:80 → LocalEmu ``creds_host:creds_port`` (#154).

        ``creds_host`` is the same compose-network IP used for
        ``AWS_ENDPOINT_URL`` (#269). Compose publishes the creds port on
        host ``127.0.0.1`` only, so DNATing to ``host.docker.internal``
        never reaches the listener inside LocalEmu.

        Programs the container netns via ``vpc_routing._sh`` so images
        without iptables (alpine, many Lambda/distroless bases) still get
        the rule through the privileged alpine sidecar. Also installs a
        /32 fib for 169.254.170.2 so ENETUNREACH does not fire before
        nat OUTPUT DNAT when the task has no default route.
        """
        try:
            import ipaddress as _ipaddress

            _ipaddress.ip_address(creds_host)
            host_lit = creds_host
            resolve = False
        except ValueError:
            host_lit = ""
            resolve = True

        # Resolve host.docker.internal only when endpoint target fell back.
        # ahostsv4 → IPv4 only (nf_tables rejects IPv6 DNAT literals).
        if resolve:
            resolve_part = (
                'CREDS_IP=$(getent ahostsv4 host.docker.internal 2>/dev/null '
                '| awk \'/STREAM/ {print $1; exit}\'); '
                'if [ -z "$CREDS_IP" ]; then '
                '  CREDS_IP=$(getent hosts host.docker.internal 2>/dev/null '
                '| awk \'$1 !~ /:/ {print $1; exit}\'); '
                'fi; '
            )
        else:
            resolve_part = f'CREDS_IP={shlex.quote(host_lit)}; '

        script = (
            'set -e; '
            + resolve_part
            + 'if [ -z "$CREDS_IP" ]; then echo "creds host unresolvable" >&2; exit 1; fi; '
            # Fib before DNAT — private awsvpc tasks have no default route.
            'ip route replace 169.254.170.2/32 via "$CREDS_IP" 2>/dev/null '
            '|| ip route replace 169.254.170.2/32 via "$CREDS_IP"; '
            'iptables -t nat -C OUTPUT -d 169.254.170.2 -p tcp --dport 80 '
            f'-j DNAT --to-destination ${{CREDS_IP}}:{int(creds_port)} 2>/dev/null '
            '|| iptables -t nat -A OUTPUT -d 169.254.170.2 -p tcp --dport 80 '
            f'-j DNAT --to-destination ${{CREDS_IP}}:{int(creds_port)}'
        )
        try:
            from localemu.services.ec2.docker.vpc_routing import _sh

            # exec → awsbox-rt netns sidecar when the image has no iptables
            _sh(docker_name, script)
            LOG.debug(
                "task-creds DNAT installed on %s → %s:%s",
                docker_name, creds_host, creds_port,
            )
        except Exception as e:
            LOG.warning(
                "Failed to install task-creds DNAT rule on %s: %s — "
                "AWS SDK calls inside the container will not reach the "
                "LocalEmu task-credentials endpoint",
                docker_name, e,
            )

    def _attach_awsvpc_sg(
        self,
        docker_name: str,
        subnet_ids: list[str] | None,
        sg_ids: list[str],
        account_id: str,
        region: str,
    ) -> None:
        try:
            from localemu.services.ec2.docker.sg_enforcement import attach_container

            attach_container(
                docker_name,
                subnet_ids=subnet_ids,
                sg_ids=sg_ids,
                account_id=account_id,
                region=region,
                kind="ecs",
            )
        except Exception:
            LOG.debug("awsvpc SG attach skipped for %s", docker_name, exc_info=True)

    def _resolve_awsvpc_network(
        self,
        subnet_ids: list[str] | None,
        account_id: str,
        region: str,
    ) -> tuple[str | None, str | None]:
        """Return ``(docker_network, gateway_ip)`` for awsvpc subnets.

        Ensures the VPC Docker bridge exists. Gateway is the host address
        on that bridge (explicit host reachability without docker0).
        """
        if not subnet_ids:
            return None, None
        try:
            from localemu.services.ec2.docker.vpc_network import (
                get_vpc_network_manager,
            )

            vpcm = get_vpc_network_manager()
            vpc_id = None
            for subnet_id in subnet_ids:
                try:
                    resolved = vpcm.get_vpc_id_for_subnet(
                        subnet_id, account_id, region,
                    )
                except Exception:
                    resolved = None
                if resolved:
                    vpc_id = resolved
                    break
            if not vpc_id:
                return None, None
            vpc_network = vpcm.ensure_network_for_vpc(vpc_id)
            if not vpc_network:
                # ensure failed (CIDR collision / pool exhausted) — do not
                # invent a network name; create would fail on a missing net.
                candidate = f"localemu-vpc-{vpc_id}"
                try:
                    DOCKER_CLIENT.inspect_network(candidate)
                    vpc_network = candidate
                except Exception:
                    return None, None
            gateway = self._docker_network_gateway(vpc_network)
            return vpc_network, gateway
        except Exception:
            LOG.debug(
                "awsvpc network resolve failed for subnets=%s",
                subnet_ids,
                exc_info=True,
            )
            return None, None

    @staticmethod
    def _docker_network_gateway(network: str) -> str | None:
        try:
            attrs = DOCKER_CLIENT.inspect_network(network)
        except Exception:
            return None
        for cfg in (attrs.get("IPAM") or {}).get("Config") or []:
            gateway = cfg.get("Gateway")
            if gateway:
                return str(gateway)
        return None

    def _detach_default_bridge(self, docker_name: str) -> None:
        """Drop the default docker bridge if still attached (#271).

        Must stay an instance method — a stray @staticmethod made
        self._detach_default_bridge(name) raise TypeError and left
        awsvpc tasks stuck off the VPC network (#360).
        """
        try:
            networks = DOCKER_CLIENT.get_networks(docker_name)
        except Exception:
            return
        if "bridge" not in networks:
            return
        try:
            DOCKER_CLIENT.disconnect_container_from_network("bridge", docker_name)
            LOG.info("ECS awsvpc task %s detached from default bridge", docker_name)
        except Exception:
            LOG.debug(
                "detach %s from bridge failed", docker_name, exc_info=True,
            )


    def _bridge_subnet_ids(
        self,
        cluster_name: str,
        network_configuration: dict | None,
        account_id: str,
        region: str,
    ) -> list[str]:
        """Subnet for bridge tasks: awsvpc config, else container-instance ENI."""
        awsvpc_cfg = (network_configuration or {}).get("awsvpcConfiguration") or {}
        configured = list(awsvpc_cfg.get("subnets") or [])
        if configured:
            return configured
        try:
            from localemu.services.ec2.docker.instance_routes import (
                _ec2_backend,
                _get_instance,
            )
            import moto.backends as moto_backends

            ecs_root = moto_backends.get_backend("ecs")
            cluster_key = cluster_name.split("/")[-1] if cluster_name else "default"
            ec2_id = None
            if isinstance(ecs_root, dict):
                regions = ecs_root.get(account_id) or {}
                backend = regions.get(region) if isinstance(regions, dict) else None
                if backend is not None:
                    cis = (getattr(backend, "container_instances", {}) or {}).get(
                        cluster_key
                    ) or {}
                    for ci in cis.values():
                        ec2_id = getattr(ci, "ec2_instance_id", None)
                        if ec2_id:
                            break
            if not ec2_id:
                return []
            ec2 = _ec2_backend(account_id, region)
            if ec2 is None:
                return []
            inst = _get_instance(ec2, str(ec2_id))
            subnet_id = getattr(inst, "subnet_id", None) if inst is not None else None
            return [str(subnet_id)] if subnet_id else []
        except Exception:
            LOG.debug(
                "bridge subnet resolve failed for cluster %s",
                cluster_name,
                exc_info=True,
            )
            return []

    def _connect_bridge_to_vpc(
        self,
        docker_name: str,
        subnet_ids: list[str] | None,
        account_id: str,
        region: str,
        task_info: EcsTaskInfo | None = None,
    ) -> str | None:
        """Attach a bridge-mode task to the subnet VPC without leaving docker0.

        Host port publish stays on the default bridge; route enforcement
        uses the VPC attachment the same way awsvpc does (#230).
        """
        if not subnet_ids:
            return None
        try:
            from localemu.services.ec2.docker.vpc_network import (
                get_vpc_network_manager,
            )

            vpcm = get_vpc_network_manager()
            vpc_id = None
            subnet_id = None
            for sid in subnet_ids:
                try:
                    resolved = vpcm.get_vpc_id_for_subnet(sid, account_id, region)
                except Exception:
                    resolved = None
                if resolved:
                    vpc_id = resolved
                    subnet_id = sid
                    break
            if not vpc_id or not subnet_id:
                return None
            if task_info is not None:
                task_info.vpc_id = vpc_id
                task_info.subnet_id = subnet_id
            try:
                ensured = vpcm.ensure_network_for_vpc(vpc_id)
            except Exception:
                ensured = None
            # Do not invent localemu-vpc-* when ensure failed (#479).
            if not ensured:
                return None
            vpc_network = ensured
            try:
                DOCKER_CLIENT.inspect_network(vpc_network)
            except Exception:
                LOG.debug("bridge VPC network %s missing", vpc_network, exc_info=True)
                return None
            networks = []
            try:
                networks = DOCKER_CLIENT.get_networks(docker_name)
            except Exception:
                networks = []
            if vpc_network not in networks:
                DOCKER_CLIENT.connect_container_to_network(vpc_network, docker_name)
            self._sync_subnet_routes(docker_name, [subnet_id], account_id, region)
            return self._container_ip_on_network(docker_name, vpc_network)
        except Exception:
            LOG.debug(
                "bridge VPC attach failed for %s", docker_name, exc_info=True,
            )
            return None

    def _connect_to_vpc_network(
        self,
        docker_name: str,
        cluster_name: str,
        subnet_ids: list[str] | None = None,
        account_id: str = "",
        region: str = "",
        task_info: EcsTaskInfo | None = None,
    ) -> str | None:
        """Connect an awsvpc-mode task container to the right VPC network.

        Pins an address from ``SubnetAllocator`` inside the subnet CIDR
        (same path as EC2/RDS) so ``DescribeTasks`` privateIPv4Address
        matches the container on ``localemu-vpc-*`` and ip-type target
        registration reaches the task (#268). Moto's
        ``random_private_ip()`` is outside the subnet and must not win.
        """
        try:
            self._detach_default_bridge(docker_name)

            if not subnet_ids:
                LOG.warning(
                    "ECS awsvpc task %s: no subnets provided — "
                    "container will not be attached to any VPC network. "
                    "Provide networkConfiguration.awsvpcConfiguration.subnets "
                    "on RunTask to enable per-VPC isolation.",
                    docker_name,
                )
                return None

            from localemu.services.ec2.docker.vpc_network import (
                get_vpc_network_manager,
            )
            vpcm = get_vpc_network_manager()

            vpc_id = None
            subnet_id = None
            for sid in subnet_ids:
                try:
                    resolved = vpcm.get_vpc_id_for_subnet(
                        sid, account_id, region,
                    )
                except Exception:
                    resolved = None
                if resolved:
                    vpc_id = resolved
                    subnet_id = sid
                    break

            if not vpc_id or not subnet_id:
                LOG.warning(
                    "ECS awsvpc task %s: none of subnets=%s resolve to a VPC in %s/%s — "
                    "skipping VPC network attach",
                    docker_name, subnet_ids, account_id, region,
                )
                return None

            if task_info is not None:
                task_info.vpc_id = vpc_id
                task_info.subnet_id = subnet_id

            try:
                ensured = vpcm.ensure_network_for_vpc(vpc_id)
            except Exception:
                ensured = None
                LOG.debug(
                    "ensure_network_for_vpc(%s) failed", vpc_id, exc_info=True,
                )
            # Do not invent localemu-vpc-* when ensure failed (#479).
            if not ensured:
                LOG.warning(
                    "ECS awsvpc task %s: no Docker network for VPC %s — "
                    "cannot pin subnet IP (CreateVpc bridge failed?)",
                    docker_name, vpc_id,
                )
                return None
            vpc_network = ensured
            try:
                DOCKER_CLIENT.inspect_network(vpc_network)
            except Exception:
                LOG.warning(
                    "ECS awsvpc task %s: VPC network %s missing — "
                    "cannot pin subnet IP (CreateVpc bridge failed?)",
                    docker_name, vpc_network,
                )
                return None

            # Create already joins localemu-vpc-* (Docker forbids connect
            # from network=none). Auto-IPAM uses the VPC /16, so drop and
            # re-attach with a SubnetAllocator address inside the /24 (#360).
            networks = []
            try:
                networks = DOCKER_CLIENT.get_networks(docker_name)
            except Exception:
                networks = []
            current_ip = self._container_ip_on_network(docker_name, vpc_network)
            if vpc_network in networks and self._ip_in_subnet(
                current_ip, subnet_id, account_id, region,
            ):
                LOG.debug(
                    "ECS container %s already pinned on %s (%s)",
                    docker_name, vpc_network, current_ip,
                )
                self._sync_subnet_routes(
                    docker_name, subnet_ids, account_id, region,
                )
                return current_ip
            if vpc_network in networks:
                try:
                    DOCKER_CLIENT.disconnect_container_from_network(
                        vpc_network, docker_name,
                    )
                    LOG.info(
                        "ECS awsvpc task %s dropped auto-IPAM on %s (%s) "
                        "to re-pin inside subnet %s",
                        docker_name, vpc_network, current_ip or "-", subnet_id,
                    )
                except Exception:
                    LOG.debug(
                        "disconnect %s from %s before re-pin failed",
                        docker_name, vpc_network, exc_info=True,
                    )

            ipv4_kwarg, reserved = self._reserve_awsvpc_ip(
                vpc_id, subnet_id, docker_name,
            )
            try:
                DOCKER_CLIENT.connect_container_to_network(
                    vpc_network, docker_name, ipv4_address=ipv4_kwarg,
                )
            except Exception:
                if reserved is not None:
                    self._release_reserved_ip(reserved)
                raise
            if reserved is not None and task_info is not None:
                task_info.reserved_ips.append(str(reserved))

            ip = ipv4_kwarg or self._container_ip_on_network(
                docker_name, vpc_network,
            )
            LOG.info(
                "ECS awsvpc task %s connected to %s (subnet=%s ip=%s)",
                docker_name, vpc_network, subnet_id, ip or "-",
            )
            self._detach_default_bridge(docker_name)
            self._sync_subnet_routes(docker_name, subnet_ids, account_id, region)
            return ip
        except Exception as e:
            LOG.warning(
                "Failed to connect container %s to VPC network: %s",
                docker_name, e,
            )
            return None

    @staticmethod
    def _ip_in_subnet(
        ip: str | None,
        subnet_id: str,
        account_id: str,
        region: str,
    ) -> bool:
        """True when ``ip`` falls inside the moto subnet CIDR."""
        if not ip:
            return False
        try:
            import ipaddress

            from localemu.services.ec2.docker.instance_routes import (
                _ec2_backend,
                _get_subnet,
            )

            backend = _ec2_backend(account_id, region)
            if backend is None:
                return False
            subnet = _get_subnet(backend, subnet_id)
            cidr = getattr(subnet, "cidr_block", None) if subnet is not None else None
            if not cidr:
                return False
            return ipaddress.ip_address(ip) in ipaddress.ip_network(str(cidr), strict=False)
        except Exception:
            return False

    def _reserve_awsvpc_ip(
        self,
        vpc_id: str,
        subnet_id: str,
        docker_name: str,
    ) -> tuple[str | None, object | None]:
        """Reserve a subnet CIDR address for awsvpc attach.

        Returns ``(ipv4_for_connect, reserved_addr_or_None)``. On allocator
        miss, falls back to Docker auto-IPAM (``None, None``).
        """
        try:
            from localemu import config as _config
        except Exception:
            return None, None
        if not getattr(_config, "LOCALEMU_VPC_IP_PINNING", True):
            return None, None
        try:
            from localemu.services.ec2.docker.subnet_allocator import (
                InsufficientFreeAddressesInSubnet,
                UnknownSubnet,
                get_subnet_allocator,
            )
            from localemu.services.ec2.docker.vm_manager import (
                _realign_subnet_pool_to_vpc_bridge,
            )
        except Exception:
            LOG.debug("awsvpc IP pin imports failed", exc_info=True)
            return None, None

        owner_key = f"eni-ecs-{docker_name.removeprefix('localemu-')}"
        try:
            _realign_subnet_pool_to_vpc_bridge(vpc_id, subnet_id)
            reserved = get_subnet_allocator().reserve(
                vpc_id=vpc_id,
                subnet_id=subnet_id,
                owner_key=owner_key,
            )
            return str(reserved), reserved
        except (UnknownSubnet, InsufficientFreeAddressesInSubnet) as e:
            LOG.warning(
                "ECS %s: cannot pin IP in subnet %s (%s) — "
                "falling back to Docker auto-IPAM",
                docker_name, subnet_id, e,
            )
            return None, None
        except Exception:
            LOG.warning(
                "ECS %s: allocator reserve raised — fall back to auto-IPAM",
                docker_name, exc_info=True,
            )
            return None, None

    @staticmethod
    def _release_reserved_ip(ip: object) -> None:
        try:
            from localemu.services.ec2.docker.subnet_allocator import (
                get_subnet_allocator,
            )

            get_subnet_allocator().release(ip)
        except Exception:
            LOG.debug("awsvpc IP release failed for %s", ip, exc_info=True)

    @staticmethod
    def _container_ip_on_network(docker_name: str, network: str) -> str | None:
        try:
            ip = DOCKER_CLIENT.get_container_ipv4_for_network(
                docker_name, network,
            )
        except TypeError:
            try:
                ip = DOCKER_CLIENT.get_container_ipv4_for_network(
                    container_name_or_id=docker_name,
                    container_network=network,
                )
            except Exception:
                return None
        except Exception:
            return None
        if not ip or ip in ("localhost", "127.0.0.1"):
            return None
        return str(ip).split("/")[0]

    def _sync_subnet_routes(
        self,
        docker_name: str,
        subnet_ids: list[str] | None,
        account_id: str,
        region: str,
    ) -> None:
        if not subnet_ids:
            return
        try:
            from localemu.services.ec2.docker.vpc_routing import sync_workload

            sync_workload(docker_name, subnet_ids[0], account_id, region)
        except Exception as exc:
            LOG.debug("vpc route sync skipped for %s: %s", docker_name, exc)

    def stop_task(self, task_arn: str) -> None:
        """Stop and remove all Docker containers for a task."""
        with self._lock:
            task_info = self._tasks.pop(task_arn, None)

        if not task_info:
            LOG.debug("No tracked containers for task %s", task_arn)
            return

        for container in task_info.containers:
            docker_name = container.docker_name
            try:
                from localemu.services.ec2.docker.sg_enforcement import (
                    release_container,
                )

                release_container(docker_name)
            except Exception:
                LOG.debug("awsvpc SG release skipped for %s", docker_name, exc_info=True)
            try:
                from localemu.services.ec2.docker.vpc_routing import (
                    unregister_workload,
                )

                unregister_workload(docker_name)
            except Exception:
                LOG.debug(
                    "vpc workload unregister skipped for %s",
                    docker_name,
                    exc_info=True,
                )
            try:
                DOCKER_CLIENT.stop_container(docker_name, timeout=10)
            except Exception:
                pass
            try:
                DOCKER_CLIENT.remove_container(docker_name)
            except Exception:
                pass
            container.status = "STOPPED"

        for ip in list(task_info.reserved_ips):
            self._release_reserved_ip(ip)
        task_info.reserved_ips.clear()

        task_info.status = "STOPPED"
        # Track stop time
        task_info.stopped_at = time.time()
        # #79: drop cached task-role credentials so the creds server
        # returns 404 for a stopped task (AWS semantics: creds revoked).
        try:
            from localemu.services.ecs.docker.task_credentials import (
                get_task_credentials_server,
            )
            task_id = task_arn.split("/")[-1]
            get_task_credentials_server().store.revoke(task_id)
        except Exception:
            LOG.debug("Failed to revoke task credentials for %s", task_arn, exc_info=True)
        LOG.info("ECS task %s stopped (%d containers)", task_arn, len(task_info.containers))

    def get_task_status(self, task_arn: str) -> EcsTaskInfo | None:
        """Inspect Docker containers and return ECS-compatible status."""
        with self._lock:
            task_info = self._tasks.get(task_arn)
        if not task_info:
            return None

        all_stopped = True
        for container in task_info.containers:
            try:
                inspect = DOCKER_CLIENT.inspect_container(container.docker_name)
                state = inspect.get("State", {})
                if isinstance(state, dict):
                    running = state.get("Running", False)
                    if running:
                        container.status = "RUNNING"
                        all_stopped = False
                    else:
                        container.status = "STOPPED"
                        container.exit_code = state.get("ExitCode")
                else:
                    # Some backends return state as a string
                    if state == "running":
                        container.status = "RUNNING"
                        all_stopped = False
                    else:
                        container.status = "STOPPED"
            except Exception:
                container.status = "STOPPED"

        if all_stopped and task_info.containers:
            task_info.status = "STOPPED"
            if not task_info.stopped_at:
                task_info.stopped_at = time.time()
            if not task_info.stopped_reason:
                task_info.stopped_reason = (
                    "Essential container in task exited"
                )

        return task_info

    def cleanup_cluster(self, cluster_name: str) -> None:
        """Stop and remove all containers belonging to a cluster."""
        # Normalize to short name — tasks may store the full ARN or short name
        cluster_short = cluster_name.split("/")[-1] if "/" in cluster_name else cluster_name
        with self._lock:
            cluster_tasks = [
                arn for arn, info in self._tasks.items()
                if (info.cluster_name.split("/")[-1] if "/" in info.cluster_name else info.cluster_name) == cluster_short
            ]

        for task_arn in cluster_tasks:
            try:
                self.stop_task(task_arn)
            except Exception as e:
                LOG.debug(
                    "Failed to clean up ECS task %s: %s", task_arn, e
                )

        LOG.info("ECS cluster %s containers cleaned up", cluster_name)

    def cleanup_all(self) -> None:
        """Stop and remove all ECS containers. Called on LocalEmu shutdown
        when persistence is OFF. Destructive — see ``stop_all_for_persistence``
        for the persistence path."""
        LOG.info("Cleaning up ECS Docker containers...")
        with self._lock:
            task_arns = list(self._tasks.keys())

        for task_arn in task_arns:
            try:
                self.stop_task(task_arn)
            except Exception as e:
                LOG.debug("Failed to clean up ECS task %s: %s", task_arn, e)

    def stop_all_for_persistence(self, timeout: int = 10) -> None:
        """Stop (but do NOT remove) every ECS task container.

        Called on LocalEmu shutdown when ``PERSISTENCE=1``. Containers
        stay on disk with their writable layer intact so
        ``EcsStateLifecycleHook.on_after_state_load`` can ``docker start``
        them on the next boot. ``self._tasks`` is kept populated — the
        labels on the containers are the source of truth anyway and
        ``_recover_orphaned_containers`` rebuilds the dict on fresh boot.
        """
        LOG.info("Stopping ECS task containers for persistence (no remove)...")
        with self._lock:
            snapshot = list(self._tasks.values())
        for task_info in snapshot:
            for container in task_info.containers:
                try:
                    DOCKER_CLIENT.stop_container(container.docker_name, timeout=timeout)
                    container.status = "STOPPED"
                except Exception as exc:
                    LOG.debug(
                        "Failed to stop ECS container %s: %s",
                        container.docker_name, exc,
                    )
            task_info.status = "STOPPED"
