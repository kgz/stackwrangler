"""Apply STACKWRANGLER_/AWSBOX_LAMBDA_DOCKER_FLAGS only to VPC Lambdas (#187).

LocalEmu's global LAMBDA_DOCKER_FLAGS would map private hostnames into every
function container. In AWS, only VpcConfig functions can reach private names.
Keep the env on the LocalEmu container and inject it at docker-run time when
the function has a VPC config; non-VPC keeps SQS QueueUrl hosts and other
per-start patches only.
"""

from __future__ import annotations

import logging
import os

LOG = logging.getLogger("localemu.awsbox.lambda_vpc_docker_flags")

_DEFAULT_FLAGS = "--add-host=host.docker.internal:host-gateway"


def _user_flags() -> str:
    for key in ("STACKWRANGLER_LAMBDA_DOCKER_FLAGS", "AWSBOX_LAMBDA_DOCKER_FLAGS"):
        if key in os.environ:
            return os.environ[key].strip()
    return _DEFAULT_FLAGS


def _has_vpc(executor) -> bool:
    cfg = getattr(getattr(executor, "function_version", None), "config", None)
    vpc = getattr(cfg, "vpc_config", None) if cfg is not None else None
    if vpc is None:
        return False
    if getattr(vpc, "vpc_id", None):
        return True
    subnets = getattr(vpc, "subnet_ids", None) or ()
    return bool(subnets)


def _merge_flags(base: str, extra: str) -> str:
    base = (base or "").strip()
    extra = (extra or "").strip()
    if not extra:
        return base
    if not base:
        return extra
    return f"{extra} {base}".strip()


def _patch_lambda() -> None:
    from localemu import config as le_config
    from localemu.services.lambda_.invocation.docker_runtime_executor import (
        DockerRuntimeExecutor,
    )

    original = DockerRuntimeExecutor._do_start

    def _do_start(self, env_vars):
        previous = le_config.LAMBDA_DOCKER_FLAGS
        try:
            if _has_vpc(self):
                le_config.LAMBDA_DOCKER_FLAGS = _merge_flags(
                    previous or "", _user_flags()
                )
            original(self, env_vars)
        finally:
            le_config.LAMBDA_DOCKER_FLAGS = previous

    DockerRuntimeExecutor._do_start = _do_start


_patch_lambda()
LOG.info("VPC-only Lambda docker flags installed (#187)")
