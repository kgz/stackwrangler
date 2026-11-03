"""Resolve sqs.<region>.localhost QueueUrls inside Lambda containers (#459).

CreateQueue / GetQueueUrl / CFN !Ref return
http://sqs.<region>.localhost:4566/<account>/<queue>. AWS SDK v3 uses that
host as the request endpoint. Lambda images do not resolve *.localhost, so
SendMessage fails with getaddrinfo ENOTFOUND.

Inject --add-host pointing at this LocalEmu container's address on the shared
Docker network. Compose publishes :4566 on 127.0.0.1 only, so host-gateway
would miss the gateway.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.sqs_queueurl_hosts")


def _queueurl_hostname(region: str) -> str:
    from localemu import config as le_config

    host = le_config.LOCALEMU_HOST.host or "localhost"
    return f"sqs.{region}.{host}"


def _emulator_ip() -> str | None:
    # Same helper as ECS AWS_ENDPOINT_URL / #269 — prefer bridge/compose net,
    # skip localemu-vpc-* so Lambda hits GATEWAY_LISTEN, not a VPC attachment.
    try:
        from localemu.services.ec2.docker.vpc_endpoint import _localemu_gateway

        ip, _net = _localemu_gateway()
        return ip or None
    except Exception:
        LOG.warning("SQS QueueUrl host: LocalEmu IP lookup failed", exc_info=True)
        return None


def _ensure_add_host(flags: str, hostname: str, ip: str) -> str:
    if f"--add-host={hostname}:" in flags or f"--add-host {hostname}:" in flags:
        return flags
    extra = f"--add-host={hostname}:{ip}"
    return f"{flags} {extra}".strip() if flags else extra


def _patch_lambda() -> None:
    from localemu import config as le_config
    from localemu.services.lambda_.invocation.docker_runtime_executor import (
        DockerRuntimeExecutor,
    )

    original = DockerRuntimeExecutor._do_start

    def _do_start(self, env_vars):
        region = getattr(getattr(self.function_version, "id", None), "region", None)
        region = region or "us-east-1"
        hostname = _queueurl_hostname(region)
        ip = _emulator_ip()
        previous = le_config.LAMBDA_DOCKER_FLAGS
        try:
            if ip:
                le_config.LAMBDA_DOCKER_FLAGS = _ensure_add_host(
                    previous or "", hostname, ip
                )
            else:
                LOG.warning(
                    "SQS QueueUrl host: no LocalEmu IP; %s will not resolve in Lambda",
                    hostname,
                )
            original(self, env_vars)
        finally:
            le_config.LAMBDA_DOCKER_FLAGS = previous

    DockerRuntimeExecutor._do_start = _do_start


_patch_lambda()
LOG.info("SQS QueueUrl host injection installed for Lambda (#459)")
