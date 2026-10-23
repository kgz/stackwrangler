"""
VPC Endpoint emulation via Docker proxy containers.

VPC Endpoints allow containers in private (--internal) Docker networks
to reach LocalEmu services (S3, DynamoDB, SQS, etc.) without internet
access.  The mechanism: a lightweight socat proxy container that bridges
the private network and the host.

Architecture:
  Private container (--internal, no host access)
      ↓ connects to proxy IP:4566
  Endpoint proxy (dual-homed: default bridge + internal network)
      ↓ socat TCP forward
  LocalEmu on host (host.docker.internal:4566)

Gateway Endpoints (S3, DynamoDB): route-table entries — single proxy
Interface Endpoints (SQS, SNS, etc.): ENI with private IP — same proxy
"""

from __future__ import annotations

import logging
import os
import tempfile
import threading

from localemu.utils.container_utils.container_client import ContainerConfiguration
from localemu.utils.docker_utils import DOCKER_CLIENT

LOG = logging.getLogger(__name__)


# Pre-baked proxy image. socat is built into the image on the LocalEmu host
# (where the internet works) instead of installed at container start via
# ``apk add``. The proxy container then runs in the VPC's --internal=true
# network and does not need outbound connectivity — running `apk add` at
# container start would fail on every VPC without an IGW route, leaving
# the proxy up but silently forwarding nothing.
_PROXY_IMAGE = "localemu/vpc-endpoint:latest"

_PROXY_DOCKERFILE = """\
FROM alpine:3.19
RUN apk add --no-cache socat \\
    && rm -rf /var/cache/apk/*
LABEL org.localemu.image-role="vpc-endpoint-proxy"
LABEL org.opencontainers.image.source="https://github.com/localemu/localemu"
LABEL org.opencontainers.image.description="LocalEmu VPC Endpoint socat proxy"
"""

_proxy_image_lock = threading.Lock()


def _localemu_gateway() -> tuple[str | None, str | None]:
    """Return ``(ipv4, network_name)`` for this LocalEmu gateway container.

    Prefer ``bridge``, then the compose/default network. Skip
    ``localemu-vpc-*`` / ``localemu-pubport*`` so a stray VPC attachment
    does not become the injected ``AWS_ENDPOINT_URL`` (#269). The proxy
    (and ECS tasks) join that network to reach GATEWAY_LISTEN without the
    loopback-only host publish.
    """
    try:
        import docker

        client = docker.from_env()
        cid = open("/etc/hostname", encoding="utf-8").read().strip()
        ctr = client.containers.get(cid)
        nets = ((ctr.attrs or {}).get("NetworkSettings") or {}).get("Networks") or {}
        if "bridge" in nets:
            addr = str((nets["bridge"] or {}).get("IPAddress") or "").split("/")[0]
            if addr:
                return addr, "bridge"
        for name, info in nets.items():
            if name.startswith("localemu-vpc-") or name.startswith("localemu-pubport"):
                continue
            addr = str((info or {}).get("IPAddress") or "").split("/")[0]
            if addr:
                return addr, name
    except Exception:
        LOG.debug("could not resolve LocalEmu gateway IP", exc_info=True)
    return None, None


def _proxy_image_available() -> bool:
    try:
        DOCKER_CLIENT.inspect_image(_PROXY_IMAGE)
        return True
    except Exception:
        return False


def _ensure_proxy_image() -> bool:
    """Build :data:`_PROXY_IMAGE` if not already present. Idempotent and
    thread-safe; mirrors the flow-log sidecar's _ensure_image so the two
    Docker-side helpers stay shaped the same way."""
    if _proxy_image_available():
        return True
    with _proxy_image_lock:
        if _proxy_image_available():
            return True
        try:
            LOG.info("Building %s (one-time, includes socat)…", _PROXY_IMAGE)
            with tempfile.TemporaryDirectory(prefix="localemu-vpce-img-") as ctx:
                dockerfile_path = os.path.join(ctx, "Dockerfile")
                with open(dockerfile_path, "w") as f:
                    f.write(_PROXY_DOCKERFILE)
                DOCKER_CLIENT.build_image(
                    dockerfile_path=dockerfile_path,
                    image_name=_PROXY_IMAGE,
                    context_path=ctx,
                )
            LOG.info("Built %s successfully", _PROXY_IMAGE)
            return True
        except Exception:
            LOG.warning(
                "VPC Endpoint proxy image build failed; falling back to "
                "runtime apk add (will not work without internet access)",
                exc_info=True,
            )
            return False


class VpcEndpointManager:
    """Manages VPC Endpoint proxy containers."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        # endpoint_id → {container_name, vpc_id, service_name, proxy_ip}
        self._endpoints: dict[str, dict] = {}

    def create_endpoint(
        self, endpoint_id: str, vpc_id: str, service_name: str,
    ) -> str | None:
        """Create a VPC Endpoint proxy container.

        The proxy container starts on the default bridge network (for
        host access), then joins the VPC's internal network.  It runs
        socat to forward port 4566 from the private network to
        host.docker.internal:4566 on the host.

        Args:
            endpoint_id: The VPC Endpoint ID (vpce-xxx)
            vpc_id: The VPC to serve
            service_name: AWS service (e.g. com.amazonaws.us-east-1.s3)

        Returns:
            The proxy's IP on the VPC network, or None on failure.
        """
        container_name = f"localemu-vpce-{endpoint_id}"
        vpc_network = f"localemu-vpc-{vpc_id}"

        try:
            # Forward to the LocalEmu gateway container IP:4566 so a
            # non-default host publish port (e.g. smoke on :24566) still works.
            # Fall back to host.docker.internal / bridge gateway when the
            # gateway IP cannot be resolved.
            gateway_ip, gateway_net = _localemu_gateway()
            host_addr = gateway_ip or "host.docker.internal"
            add_host_flag = ""
            if host_addr == "host.docker.internal":
                add_host_flag = "--add-host host.docker.internal:host-gateway"
                try:
                    DOCKER_CLIENT.run_container(
                        "alpine:3.19",
                        additional_flags="--add-host host.docker.internal:host-gateway",
                        command=["getent", "hosts", "host.docker.internal"],
                        remove=True,
                    )
                except Exception:
                    try:
                        bridge_info = DOCKER_CLIENT.inspect_network("bridge")
                        ipam_config = bridge_info.get("IPAM", {}).get("Config", [{}])
                        gateway = (
                            ipam_config[0].get("Gateway", "172.17.0.1")
                            if ipam_config
                            else "172.17.0.1"
                        )
                        host_addr = gateway
                        add_host_flag = f"--add-host host.docker.internal:{gateway}"
                        LOG.info(
                            "Using Docker bridge gateway %s as host address for VPC endpoints",
                            gateway,
                        )
                    except Exception:
                        host_addr = "172.17.0.1"
                        add_host_flag = "--add-host host.docker.internal:172.17.0.1"
            else:
                LOG.info("VPC endpoint proxy forwarding to LocalEmu at %s:4566", host_addr)

            # Start on default bridge (can reach the gateway container IP).
            # Use the baked image with socat pre-installed; only fall back to
            # alpine + runtime apk add if the build itself failed.
            if _ensure_proxy_image():
                image_name = _PROXY_IMAGE
                command = [
                    "sh", "-c",
                    f"socat TCP-LISTEN:4566,fork,reuseaddr TCP:{host_addr}:4566 & "
                    f"socat TCP-LISTEN:443,fork,reuseaddr TCP:{host_addr}:4566 & "
                    "while true; do sleep 3600; done",
                ]
            else:
                image_name = "alpine:3.19"
                command = [
                    "sh", "-c",
                    "apk add --no-cache socat >/dev/null 2>&1; "
                    f"socat TCP-LISTEN:4566,fork,reuseaddr TCP:{host_addr}:4566 & "
                    f"socat TCP-LISTEN:443,fork,reuseaddr TCP:{host_addr}:4566 & "
                    "while true; do sleep 3600; done",
                ]
            config = ContainerConfiguration(
                image_name=image_name,
                name=container_name,
                command=command,
                additional_flags=add_host_flag or None,
                detach=True,
                labels={
                    "localemu.service": "vpc-endpoint",
                    "localemu.endpoint-id": endpoint_id,
                    "localemu.vpc-id": vpc_id,
                    "localemu.service-name": service_name,
                },
            )
            DOCKER_CLIENT.create_container_from_config(config)
            DOCKER_CLIENT.start_container(container_name)

            # Share a network with the LocalEmu gateway when forwarding to its IP.
            if gateway_ip and gateway_net and gateway_net != "bridge":
                try:
                    DOCKER_CLIENT.connect_container_to_network(gateway_net, container_name)
                except Exception:
                    LOG.debug(
                        "could not attach %s to gateway network %s",
                        container_name,
                        gateway_net,
                        exc_info=True,
                    )

            # Connect to VPC's internal network
            DOCKER_CLIENT.connect_container_to_network(vpc_network, container_name)

            # Use exponential backoff starting at 0.2s instead of flat 1s
            import time
            proxy_ip = None
            backoff = 0.2
            for _ in range(10):
                try:
                    proxy_ip = DOCKER_CLIENT.get_container_ipv4_for_network(
                        container_name, vpc_network
                    )
                    if proxy_ip:
                        break
                except Exception:
                    pass
                time.sleep(backoff)
                backoff = min(backoff * 2, 3.0)  # Cap at 3s

            # Generate a proper DNS name for the endpoint
            # Format: vpce-{id}.{service}.{region}.vpce.amazonaws.com
            service_short = service_name.rsplit(".", 1)[-1] if "." in service_name else service_name
            region_part = service_name.split(".")[-2] if service_name.count(".") >= 3 else "us-east-1"
            dns_name = f"{endpoint_id}.{service_short}.{region_part}.vpce.localemu.cloud"

            with self._lock:
                self._endpoints[endpoint_id] = {
                    "container_name": container_name,
                    "vpc_id": vpc_id,
                    "service_name": service_name,
                    "proxy_ip": proxy_ip,
                    "dns_name": dns_name,
                }

            LOG.info(
                "VPC Endpoint %s created for %s in VPC %s (proxy=%s, dns=%s)",
                endpoint_id, service_name, vpc_id, proxy_ip, dns_name,
            )
            return proxy_ip

        except Exception as e:
            LOG.warning("Failed to create VPC Endpoint %s: %s", endpoint_id, e)
            # Clean up any partially created resources ()
            try:
                DOCKER_CLIENT.stop_container(container_name, timeout=5)
            except Exception:
                pass
            try:
                DOCKER_CLIENT.remove_container(container_name)
            except Exception:
                pass
            return None

    def delete_endpoint(self, endpoint_id: str) -> None:
        """Remove a VPC Endpoint proxy container."""
        with self._lock:
            ep = self._endpoints.pop(endpoint_id, None)
            if not ep:
                return
            container_name = ep["container_name"]

        try:
            DOCKER_CLIENT.stop_container(container_name, timeout=5)
        except Exception:
            pass
        try:
            DOCKER_CLIENT.remove_container(container_name)
        except Exception:
            pass

        LOG.info("VPC Endpoint %s deleted", endpoint_id)

    def get_endpoint_ip(self, endpoint_id: str) -> str | None:
        """Return the proxy IP for a VPC Endpoint."""
        with self._lock:
            ep = self._endpoints.get(endpoint_id)
            return ep["proxy_ip"] if ep else None

    def get_endpoint_dns(self, endpoint_id: str) -> str | None:
        """Return the DNS name for a VPC Endpoint ()."""
        with self._lock:
            ep = self._endpoints.get(endpoint_id)
            return ep.get("dns_name") if ep else None

    def get_endpoints_for_vpc(self, vpc_id: str) -> list[dict]:
        """Return all VPC Endpoints for a VPC."""
        with self._lock:
            return [
                {"endpoint_id": eid, **ep}
                for eid, ep in self._endpoints.items()
                if ep["vpc_id"] == vpc_id
            ]

    def cleanup_all(self) -> None:
        """Remove all VPC Endpoint proxy containers."""
        with self._lock:
            endpoint_ids = list(self._endpoints.keys())
        for eid in endpoint_ids:
            self.delete_endpoint(eid)


# Module-level singleton
_endpoint_manager: VpcEndpointManager | None = None
_endpoint_lock = threading.Lock()


def get_vpc_endpoint_manager() -> VpcEndpointManager:
    global _endpoint_manager
    if _endpoint_manager is None:
        with _endpoint_lock:
            if _endpoint_manager is None:
                _endpoint_manager = VpcEndpointManager()
    return _endpoint_manager
