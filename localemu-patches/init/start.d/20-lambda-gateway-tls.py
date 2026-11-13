"""Lambda https AWS_ENDPOINT_URL + gateway CA (#696).

Upstream injects ``AWS_ENDPOINT_URL=http://<compose-ip>:4566``. Rewrite to
``https://localemu.awsbox:<port>`` (cert SAN), mount the gateway CA, and set
``AWS_CA_BUNDLE`` / ``NODE_EXTRA_CA_CERTS`` / ``SSL_CERT_FILE`` so
``aws:SecureTransport`` matches ECS (#687).
"""

from __future__ import annotations

import logging
import sys

LOG = logging.getLogger("localemu.awsbox.lambda_gateway_tls")

if "/opt/awsbox/tls" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/tls")


def _emulator_ip() -> str | None:
    try:
        from localemu.services.ec2.docker.vpc_endpoint import _localemu_gateway

        ip, _net = _localemu_gateway()
        return ip or None
    except Exception:
        LOG.warning("lambda gateway TLS: LocalEmu IP lookup failed", exc_info=True)
        return None


def _patch_lambda() -> None:
    import awsbox_gateway_tls as gateway_tls
    from localemu import config as le_config
    from localemu.services.lambda_.invocation.docker_runtime_executor import (
        DockerRuntimeExecutor,
    )

    original = DockerRuntimeExecutor._do_start
    port = le_config.GATEWAY_LISTEN[0].port

    def _do_start(self, env_vars):
        # Always set https endpoint when LocalEmu would inject one (default on).
        if not le_config.LAMBDA_DISABLE_AWS_ENDPOINT_URL:
            gateway_tls.apply_https_endpoint(env_vars, port=port)
            gateway_tls.apply_ca_env(env_vars)

        previous = le_config.LAMBDA_DOCKER_FLAGS
        try:
            ip = _emulator_ip()
            if ip and not le_config.LAMBDA_DISABLE_AWS_ENDPOINT_URL:
                le_config.LAMBDA_DOCKER_FLAGS = gateway_tls.docker_tls_flags(
                    previous or "", ip
                )
            elif not ip:
                LOG.warning(
                    "lambda gateway TLS: no LocalEmu IP; %s may not resolve",
                    gateway_tls.EMU_DNS_NAME,
                )
            original(self, env_vars)
        finally:
            le_config.LAMBDA_DOCKER_FLAGS = previous

    DockerRuntimeExecutor._do_start = _do_start


_patch_lambda()
LOG.info("Lambda gateway TLS endpoint injection installed (#696)")
