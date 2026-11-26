"""Enforce Lambda MemorySize as Docker mem_limit + nano_cpus; REPORT Max Memory Used (#688/#689).

Upstream only sets AWS_LAMBDA_FUNCTION_MEMORY_SIZE. Without mem_limit the
container can allocate past MemorySize (no Runtime.OutOfMemory) and the
RAPID REPORT line repeats Memory Size as Max Memory Used. Cap the container
at MemorySize and rewrite Max Memory Used from cgroup memory.peak.

On AWS, CPU scales with MemorySize (1769 MB = 1 vCPU). ContainerConfiguration
has no nano_cpus field and docker-py's update_container lacks nano_cpus, so we
permanently wrap ContainerCollection.create to pass nano_cpus at create time
(#689) — same race-safe pattern as the mem_limit wrap.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
from concurrent.futures import Future
from concurrent.futures import TimeoutError as FuturesTimeoutError

LOG = logging.getLogger("localemu.awsbox.lambda_memory_limit")

_REPORT_MAX_RE = re.compile(r"(Max Memory Used:\s*)(\d+)(\s*MB)")
_CGROUP_PEAK_PATHS = (
    "/sys/fs/cgroup/memory.peak",
    "/sys/fs/cgroup/memory.max_usage_in_bytes",
    "/sys/fs/cgroup/memory/memory.max_usage_in_bytes",
)
_INVOKE_TIMEOUT_BUFFER_SECONDS = 5
_OOM_POLL_SECONDS = 0.15
# AWS Lambda: 1769 MB memory ≈ 1 vCPU
_MB_PER_VCPU = 1769
_NANOS_PER_CPU = 1_000_000_000


def _memory_size_mb(executor) -> int | None:
    try:
        return int(executor.function_version.config.memory_size)
    except (TypeError, ValueError, AttributeError):
        return None


def _nano_cpus_from_memory(memory_mb: int) -> int:
    """memory_mb / 1769 * 1e9, capped at the host CPU count."""
    nano = memory_mb * _NANOS_PER_CPU // _MB_PER_VCPU
    host_cpus = os.cpu_count() or 1
    return max(1, min(nano, host_cpus * _NANOS_PER_CPU))


def _memory_mb_from_environment(environment) -> int | None:
    """Parse AWS_LAMBDA_FUNCTION_MEMORY_SIZE from docker-py environment kwarg."""
    if isinstance(environment, dict):
        raw = environment.get("AWS_LAMBDA_FUNCTION_MEMORY_SIZE")
    elif isinstance(environment, (list, tuple)):
        raw = None
        for item in environment:
            if not isinstance(item, str):
                continue
            if item.startswith("AWS_LAMBDA_FUNCTION_MEMORY_SIZE="):
                raw = item.split("=", 1)[1]
                break
    else:
        return None
    if raw is None or raw == "":
        return None
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None

def _oom_killed(container_client, container_name: str) -> bool:
    try:
        inspect = container_client.inspect_container(container_name)
        state = inspect.get("State") or {}
        return bool(state.get("OOMKilled"))
    except Exception:
        LOG.debug("lambda memory: inspect OOMKilled failed for %s", container_name, exc_info=True)
        return False


def _read_peak_mb(container_client, container_name: str) -> int | None:
    for path in _CGROUP_PEAK_PATHS:
        try:
            stdout, _stderr = container_client.exec_in_container(
                container_name, ["cat", path], user="root"
            )
            raw = stdout.decode(errors="replace").strip().split()[0]
            if not raw or raw == "max":
                continue
            bytes_used = int(raw)
            return max(1, (bytes_used + 1024 * 1024 - 1) // (1024 * 1024))
        except Exception:
            continue
    return None


def _reset_peak(container_client, container_name: str) -> None:
    try:
        container_client.exec_in_container(
            container_name,
            ["sh", "-c", "printf 0 >/sys/fs/cgroup/memory.peak 2>/dev/null || true"],
            user="root",
        )
    except Exception:
        LOG.debug("lambda memory: reset memory.peak failed for %s", container_name, exc_info=True)


def _rewrite_max_memory(logs: str | None, peak_mb: int | None) -> str | None:
    if logs is None or peak_mb is None:
        return logs
    return _REPORT_MAX_RE.sub(rf"\g<1>{peak_mb}\g<3>", logs)


def _oom_result(request_id: str, memory_size: int, peak_mb: int):
    from localemu.services.lambda_.invocation.lambda_models import InvocationResult

    payload = {
        "errorType": "Runtime.OutOfMemory",
        "errorMessage": (
            f"RequestId: {request_id} Error: Runtime exited with error: signal: killed"
        ),
    }
    report = (
        f"REPORT RequestId: {request_id}\tDuration: 0.00 ms\t"
        f"Billed Duration: 1 ms\tMemory Size: {memory_size} MB\t"
        f"Max Memory Used: {peak_mb} MB\t"
        f"Status: error\tError Type: Runtime.OutOfMemory\n"
    )
    return InvocationResult(
        request_id=request_id,
        payload=json.dumps(payload).encode(),
        is_error=True,
        logs=report,
    )


def _memory_mb_from_env(container_config) -> int | None:
    return _memory_mb_from_environment(getattr(container_config, "env_vars", None) or {})


def _patch_lambda() -> None:
    from docker.models.containers import ContainerCollection

    from localemu.services.lambda_.invocation.docker_runtime_executor import (
        DockerRuntimeExecutor,
    )
    from localemu.services.lambda_.invocation.executor_endpoint import InvokeSendError
    from localemu.utils.docker_utils import DOCKER_CLIENT as CONTAINER_CLIENT

    # Permanent wrap (not swap-restore): concurrent cold starts must not
    # unwind each other's create_container_from_config (#815 review).
    if not getattr(CONTAINER_CLIENT.create_container_from_config, "_awsbox_lambda_mem", False):
        orig_create = CONTAINER_CLIENT.create_container_from_config

        def create_container_from_config(container_config):
            memory_mb = _memory_mb_from_env(container_config)
            if memory_mb and not getattr(container_config, "mem_limit", None):
                container_config.mem_limit = f"{memory_mb}m"
            return orig_create(container_config)

        setattr(create_container_from_config, "_awsbox_lambda_mem", True)
        CONTAINER_CLIENT.create_container_from_config = create_container_from_config

    # ContainerConfiguration has no nano_cpus; inject at SDK create (#689).
    # Class-level wrap: client.containers is a new collection each access.
    if not getattr(ContainerCollection.create, "_awsbox_lambda_cpu", False):
        orig_sdk_create = ContainerCollection.create

        def create(self, image, command=None, **kwargs):
            if not kwargs.get("nano_cpus"):
                memory_mb = _memory_mb_from_environment(kwargs.get("environment"))
                if memory_mb:
                    kwargs["nano_cpus"] = _nano_cpus_from_memory(memory_mb)
            return orig_sdk_create(self, image, command=command, **kwargs)

        setattr(create, "_awsbox_lambda_cpu", True)
        ContainerCollection.create = create

    def invoke(self, payload, function_timeout=None):
        request_id = ""
        if isinstance(payload, dict):
            request_id = str(payload.get("invoke-id") or "")
        memory_size = _memory_size_mb(self) or 128
        _reset_peak(CONTAINER_CLIENT, self.container_name)

        endpoint = self.executor_endpoint
        endpoint.invocation_future = Future()
        endpoint.logs = None
        if not endpoint.container_address:
            raise ValueError("Container address not set, but got an invoke.")
        invocation_url = (
            f"http://{endpoint.container_address}:{endpoint.container_port}/invoke"
        )
        proxies = {"http": "", "https": ""}
        response = endpoint._perform_invoke(
            invocation_url=invocation_url, proxies=proxies, payload=payload
        )
        if not response.ok:
            raise InvokeSendError(
                f"Error while sending invocation {payload} to {invocation_url}. "
                f"Error Code: {response.status_code}"
            )

        if function_timeout is not None:
            timeout_seconds = function_timeout + _INVOKE_TIMEOUT_BUFFER_SECONDS
        else:
            timeout_seconds = 900 + _INVOKE_TIMEOUT_BUFFER_SECONDS

        deadline = time.monotonic() + timeout_seconds
        while time.monotonic() < deadline:
            if endpoint.invocation_future.done():
                result = endpoint.invocation_future.result(timeout=0)
                break
            if _oom_killed(CONTAINER_CLIENT, self.container_name):
                peak = _read_peak_mb(CONTAINER_CLIENT, self.container_name) or memory_size
                return _oom_result(request_id, memory_size, peak)
            time.sleep(_OOM_POLL_SECONDS)
        else:
            if _oom_killed(CONTAINER_CLIENT, self.container_name):
                peak = _read_peak_mb(CONTAINER_CLIENT, self.container_name) or memory_size
                return _oom_result(request_id, memory_size, peak)
            raise FuturesTimeoutError(
                f"Lambda invoke timed out after {timeout_seconds}s "
                f"(function_timeout={function_timeout})"
            )

        if _oom_killed(CONTAINER_CLIENT, self.container_name):
            peak = _read_peak_mb(CONTAINER_CLIENT, self.container_name) or memory_size
            return _oom_result(request_id, memory_size, peak)

        peak = _read_peak_mb(CONTAINER_CLIENT, self.container_name)
        if peak is not None and result is not None and result.logs:
            result.logs = _rewrite_max_memory(result.logs, peak)
        return result

    DockerRuntimeExecutor.invoke = invoke


_patch_lambda()
LOG.info(
    "Lambda MemorySize mem_limit + nano_cpus + cgroup Max Memory Used installed (#688/#689)"
)
