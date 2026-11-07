"""VPC Docker network lifecycle fixes (#479).

- CreateVpc fails (moto VPC rolled back) when the Docker bridge cannot be
  allocated, instead of succeeding with only a WARN in the emulator log.
- ensure_network_for_vpc retries after a prior failure so VPC Lambda / ECS
  can recover once colliding bridges are gone.
- Before upstream adopt, reclaim orphan bridges held only by this compose
  project's LocalEmu containers (``localemu-*`` and
  ``${compose}-localstack*``), matching ``bin/stackwrangler`` cleanup —
  never a broad ``*-lambda-*`` match on a shared Docker host.
- Test hook: if ``/var/lib/awsbox/vpc-bridge-boom`` exists, bridge create
  returns failure so smokes can assert CreateVpc rollback without exhausting
  host IPAM.
"""

from __future__ import annotations

import logging
import os
import time

LOG = logging.getLogger("localemu.awsbox.vpc_network_lifecycle")

# Short gate so a permanently broken Docker host does not WARN on every
# Lambda poll, while still retrying quickly after the operator frees CIDRs.
_ENSURE_RETRY_TTL_SECONDS = 5

# Mounted from compose ``./.awsbox:/var/lib/awsbox`` — smoke touches this file.
_BRIDGE_BOOM_FLAG = "/var/lib/awsbox/vpc-bridge-boom"


def _own_localstack_prefix() -> str | None:
    """Return ``<compose_project>-localstack`` for this emulator, if known."""
    try:
        from localemu.utils.container_networking import get_main_container_name

        main = (get_main_container_name() or "").lstrip("/")
    except Exception:
        return None
    marker = "-localstack"
    idx = main.find(marker)
    if idx < 0:
        return None
    return main[: idx + len(marker)]


def _is_owned_container(name: str) -> bool:
    # Same ownership bar as bin/stackwrangler cleanup_localemu_vpc_networks:
    # localemu-* sidecars, or this project's localstack (+ its lambda children).
    if name.startswith("localemu-"):
        return True
    prefix = _own_localstack_prefix()
    return bool(prefix and name.startswith(prefix))


def _patch_ensure_network_for_vpc() -> None:
    from localemu.services.ec2.docker.vpc_network import VpcNetworkManager

    original = VpcNetworkManager.ensure_network_for_vpc
    if getattr(original, "_awsbox_vpc_net_lifecycle_ensure", False):
        return

    def ensure_network_for_vpc(self, vpc_id: str) -> str | None:
        with self._lock:
            vpc_info = self._vpcs.get(vpc_id)
            if vpc_info and vpc_info.get("network_id"):
                return vpc_info["network_name"]
            ts = self._failed_creates.get(vpc_id)
            if ts is not None and (time.time() - ts) < _ENSURE_RETRY_TTL_SECONDS:
                return None
            # Drop the upstream 300s CreateVpc cooldown so Lambda/ECS can
            # retry after a colliding bridge is removed (#479).
            self._failed_creates.pop(vpc_id, None)

        name = original(self, vpc_id)
        if name and self.is_network_ready(vpc_id):
            return name
        return None

    ensure_network_for_vpc._awsbox_vpc_net_lifecycle_ensure = True
    VpcNetworkManager.ensure_network_for_vpc = ensure_network_for_vpc


def _patch_adopt_owned_orphans() -> None:
    from localemu.services.ec2.docker.vpc_network import (
        VPC_NETWORK_PREFIX,
        VpcNetworkManager,
    )
    from localemu.utils.docker_utils import DOCKER_CLIENT

    original_adopt = VpcNetworkManager.adopt_vpc_networks_from_docker
    if getattr(original_adopt, "_awsbox_vpc_net_lifecycle_adopt", False):
        return

    def adopt_vpc_networks_from_docker(self) -> tuple[int, int]:
        _pre_reclaim_owned_orphans(self, DOCKER_CLIENT, VPC_NETWORK_PREFIX)
        return original_adopt(self)

    adopt_vpc_networks_from_docker._awsbox_vpc_net_lifecycle_adopt = True
    VpcNetworkManager.adopt_vpc_networks_from_docker = adopt_vpc_networks_from_docker


def _pre_reclaim_owned_orphans(manager, docker_client, vpc_prefix: str) -> None:
    """Remove orphan bridges held only by this project's LocalEmu containers.

    Bridges with any foreign endpoint (other worktree lambdas, user
    containers, etc.) are left alone.
    """
    try:
        import subprocess as _sp

        ls = _sp.run(
            [
                "docker",
                "network",
                "ls",
                "--format",
                "{{.Name}}",
                "--filter",
                f"name={vpc_prefix}",
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except Exception:
        return
    if ls.returncode != 0:
        return

    for name in (n.strip() for n in ls.stdout.splitlines() if n.strip()):
        if not name.startswith(vpc_prefix):
            continue
        vpc_id = name.removeprefix(vpc_prefix)
        if not vpc_id.startswith("vpc-"):
            continue
        if manager._lookup_vpc_cidr_in_moto(vpc_id) is not None:
            continue
        try:
            info = docker_client.inspect_network(name) or {}
        except Exception:
            continue
        attached = [
            (entry.get("Name") or "").lstrip("/")
            for entry in (info.get("Containers") or {}).values()
        ]
        attached = [n for n in attached if n]
        if not attached:
            continue
        if any(not _is_owned_container(n) for n in attached):
            continue
        for owned in attached:
            try:
                docker_client.stop_container(owned, timeout=5)
            except Exception:
                pass
            try:
                docker_client.remove_container(owned, force=True)
            except Exception:
                LOG.debug(
                    "pre-adopt: could not remove leftover %s on %s",
                    owned,
                    name,
                    exc_info=True,
                )
        try:
            docker_client.delete_network(name)
            LOG.info(
                "pre-adopt: reclaimed orphan VPC bridge %s (owned leftovers)",
                name,
            )
        except Exception:
            LOG.debug("pre-adopt: could not delete %s", name, exc_info=True)


def _wrap_bridge_boom_flag() -> None:
    """Fail Docker bridge create when the smoke sentinel file is present."""
    from localemu.services.ec2.docker.vpc_network import VpcNetworkManager

    original = VpcNetworkManager._create_docker_bridge
    if getattr(original, "_awsbox_vpc_bridge_boom", False):
        return

    def _create_docker_bridge(self, vpc_id, network_name, cidr_block, internal):
        if os.path.exists(_BRIDGE_BOOM_FLAG):
            LOG.warning(
                "vpc-bridge-boom flag set; refusing Docker network for %s",
                vpc_id,
            )
            return None, None
        return original(self, vpc_id, network_name, cidr_block, internal)

    _create_docker_bridge._awsbox_vpc_bridge_boom = True
    VpcNetworkManager._create_docker_bridge = _create_docker_bridge


def _wrap_create_vpc() -> None:
    from localemu.aws.api import CommonServiceException
    from localemu.services.ec2.provider import Ec2Provider

    original = Ec2Provider.create_vpc
    if getattr(original, "_awsbox_vpc_net_lifecycle", False):
        return

    def create_vpc(self, *args, **kwargs):
        # Preserve ASF handler dispatch (*args/**kwargs — expand=False vs
        # expanded shape). Do not narrow the signature or the gateway calls
        # us with cidr_block=… and 500s.
        result = original(self, *args, **kwargs)
        if not isinstance(result, dict):
            return result
        vpc = result.get("Vpc") or {}
        vpc_id = vpc.get("VpcId")
        if not vpc_id:
            return result
        context = args[0] if args else kwargs.get("context")
        try:
            from localemu.services.ec2.docker.vpc_network import get_vpc_network_manager
            from localemu.utils.docker_utils import DOCKER_CLIENT

            if not DOCKER_CLIENT.has_docker():
                return result
            mgr = get_vpc_network_manager()
            if mgr.is_network_ready(vpc_id):
                return result
            # Upstream create_vpc may have swallowed the bridge failure.
            mgr.ensure_network_for_vpc(vpc_id)
            if mgr.is_network_ready(vpc_id):
                return result
        except CommonServiceException:
            raise
        except Exception:
            LOG.warning(
                "CreateVpc Docker network check failed for %s",
                vpc_id,
                exc_info=True,
            )
            # Fall through to rollback — bridge is not confirmed ready.

        _rollback_moto_vpc(context, vpc_id)
        raise CommonServiceException(
            "InternalError",
            (
                f"LocalEmu could not allocate a Docker network for VPC {vpc_id}. "
                "A CIDR may collide with a leftover localemu-vpc-* bridge, or "
                "fallback pools are exhausted. Run `./bin/stackwrangler down` "
                "(removes empty localemu-vpc-* networks) or "
                "`docker network prune`, then retry CreateVpc."
            ),
            status_code=500,
        )

    # Keep operation metadata so expand=False (and friends) still apply.
    for attr, value in original.__dict__.items():
        setattr(create_vpc, attr, value)
    create_vpc._awsbox_vpc_net_lifecycle = True
    Ec2Provider.create_vpc = create_vpc


def _rollback_moto_vpc(context, vpc_id: str) -> None:
    try:
        from moto.ec2.models import ec2_backends

        account_id = getattr(context, "account_id", None) or "000000000000"
        region = getattr(context, "region", None) or "us-east-1"
        backend = ec2_backends[account_id][region]
        backend.delete_vpc(vpc_id)
    except Exception:
        LOG.warning(
            "failed to roll back moto VPC %s after Docker network failure",
            vpc_id,
            exc_info=True,
        )
    try:
        from localemu.services.ec2.docker.vpc_network import get_vpc_network_manager

        get_vpc_network_manager().delete_vpc_network(vpc_id)
    except Exception:
        LOG.debug(
            "docker network cleanup after CreateVpc rollback raised",
            exc_info=True,
        )


def _install_after_ec2_init() -> None:
    """Re-apply wraps after Ec2Provider.init / apply_patches (and #386 bridge wrap)."""
    from localemu.services.ec2.provider import Ec2Provider

    previous = Ec2Provider.on_after_init
    if getattr(previous, "_awsbox_vpc_net_lifecycle_after", False):
        return

    def on_after_init(self, *args, **kwargs):
        out = previous(self, *args, **kwargs) if previous is not None else None
        try:
            _wrap_bridge_boom_flag()
            _wrap_create_vpc()
            _patch_ensure_network_for_vpc()
        except Exception:
            LOG.warning("vpc network lifecycle late install failed", exc_info=True)
        return out

    on_after_init._awsbox_vpc_net_lifecycle_after = True
    Ec2Provider.on_after_init = on_after_init


_patch_ensure_network_for_vpc()
_patch_adopt_owned_orphans()
_wrap_bridge_boom_flag()
_wrap_create_vpc()
_install_after_ec2_init()
LOG.info("awsbox VPC Docker network lifecycle installed (#479)")
