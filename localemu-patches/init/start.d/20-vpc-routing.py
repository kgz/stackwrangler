"""Install VPC route-table enforcement on EC2 launch and route changes."""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.vpc_routing")


def _patch_routes() -> None:
    import localemu.services.ec2.docker.instance_routes as instance_routes
    from localemu.services.ec2.docker.vpc_routing import (
        sync_route_table,
        sync_subnet,
    )

    original_change = instance_routes.on_route_table_change
    original_delete = instance_routes.on_route_delete
    original_rebind = instance_routes.on_subnet_rebound_to_route_table

    def on_route_table_change(*, route_table_id: str, account_id: str, region: str) -> int:
        applied = original_change(
            route_table_id=route_table_id,
            account_id=account_id,
            region=region,
        )
        try:
            sync_route_table(route_table_id, account_id, region)
        except Exception:
            LOG.warning("route sync after route-table change failed", exc_info=True)
        return applied

    def on_route_delete(
        *,
        route_table_id: str,
        destination_cidr: str,
        account_id: str,
        region: str,
    ) -> int:
        removed = original_delete(
            route_table_id=route_table_id,
            destination_cidr=destination_cidr,
            account_id=account_id,
            region=region,
        )
        try:
            sync_route_table(route_table_id, account_id, region)
        except Exception:
            LOG.warning("route sync after DeleteRoute failed", exc_info=True)
        return removed

    def on_subnet_rebound_to_route_table(*, subnet_id: str, account_id: str, region: str) -> int:
        applied = original_rebind(
            subnet_id=subnet_id,
            account_id=account_id,
            region=region,
        )
        try:
            sync_subnet(subnet_id, account_id, region)
        except Exception:
            LOG.warning("route sync after route-table rebind failed", exc_info=True)
        return applied

    instance_routes.on_route_table_change = on_route_table_change
    instance_routes.on_route_delete = on_route_delete
    instance_routes.on_subnet_rebound_to_route_table = on_subnet_rebound_to_route_table


def _patch_launch() -> None:
    from localemu.services.ec2.docker.vm_manager import DockerVmManager
    from localemu.services.ec2.docker.vpc_routing import peered_vpc_ids, sync_vpc

    original = DockerVmManager.create_instance

    def create_instance(self, *args, **kwargs):
        info = original(self, *args, **kwargs)
        try:
            vpc_id = getattr(info, "vpc_id", None)
            if not vpc_id:
                return info
            account_id = str(kwargs.get("account_id") or "000000000000")
            region = str(kwargs.get("region") or "us-east-1")
            sync_vpc(vpc_id, account_id, region)
            for peer_vpc_id in peered_vpc_ids(vpc_id):
                sync_vpc(peer_vpc_id, account_id, region)
        except Exception:
            LOG.warning("vpc route sync after RunInstances failed", exc_info=True)
        return info

    DockerVmManager.create_instance = create_instance


def _patch_nat_and_peering() -> None:
    from localemu.services.ec2.docker.nat_gateway import NatGatewayManager
    from localemu.services.ec2.docker.vpc_network import VpcNetworkManager
    from localemu.services.ec2.docker.vpc_routing import sync_vpc

    original_nat = NatGatewayManager.create_nat_gateway
    original_peering = VpcNetworkManager.create_peering

    def create_nat_gateway(self, nat_id: str, vpc_id: str, subnet_id: str):
        created = original_nat(self, nat_id, vpc_id, subnet_id)
        try:
            sync_vpc(vpc_id)
        except Exception:
            LOG.warning("vpc route sync after CreateNatGateway failed", exc_info=True)
        return created

    def create_peering(self, peering_id: str, vpc1_id: str, vpc2_id: str) -> None:
        original_peering(self, peering_id, vpc1_id, vpc2_id)
        try:
            sync_vpc(vpc1_id)
            sync_vpc(vpc2_id)
        except Exception:
            LOG.warning("vpc route sync after peering accept failed", exc_info=True)

    NatGatewayManager.create_nat_gateway = create_nat_gateway
    VpcNetworkManager.create_peering = create_peering


def _patch_lambda() -> None:
    from localemu.services.lambda_.invocation.docker_runtime_executor import (
        DockerRuntimeExecutor,
    )
    from localemu.services.ec2.docker.vpc_routing import (
        lambda_subnet_networks,
        sync_workload,
        unregister_workload,
    )

    original_networks = DockerRuntimeExecutor._get_networks_for_executor
    original_start = DockerRuntimeExecutor.start
    original_stop = DockerRuntimeExecutor.stop

    def _lambda_subnet(self) -> tuple[str | None, str, str]:
        function_version = getattr(self, "function_version", None)
        config = getattr(function_version, "config", None)
        vpc_config = getattr(config, "vpc_config", None) if config is not None else None
        ident = getattr(function_version, "id", None)
        account_id = str(getattr(ident, "account", None) or "000000000000")
        region = str(getattr(ident, "region", None) or "us-east-1")
        if vpc_config is None:
            return None, account_id, region
        subnet_ids = list(getattr(vpc_config, "subnet_ids", None) or [])
        subnet_id = subnet_ids[0] if subnet_ids else None
        return subnet_id, account_id, region

    def _get_networks_for_executor(self):
        networks = list(original_networks(self))
        try:
            for network in lambda_subnet_networks(self):
                if network not in networks:
                    networks.append(network)
        except Exception:
            LOG.debug("lambda subnet network attach failed", exc_info=True)
        return networks

    def start(self, *args, **kwargs):
        # Route/iptables sync uses a privileged alpine netns sidecar
        # (localemu/awsbox-rt via _sh_netns) — Lambda containers stay
        # non-privileged (#230).
        subnet_id, account_id, region = _lambda_subnet(self)
        result = original_start(self, *args, **kwargs)
        try:
            name = getattr(self, "container_name", None)
            if subnet_id and name:
                sync_workload(name, subnet_id, account_id, region)
        except Exception:
            LOG.warning("vpc route sync after Lambda start failed", exc_info=True)
        return result

    def stop(self, *args, **kwargs):
        # Keep workload registry across stop/start so docker restart can
        # replay routes (#230). Unregister only when the container is gone.
        name = getattr(self, "container_name", None)
        result = original_stop(self, *args, **kwargs)
        if name:
            try:
                from localemu.utils.docker_utils import DOCKER_CLIENT

                if not DOCKER_CLIENT.is_container_running(name):
                    # Still registered for replay after a temporary stop;
                    # drop only if the container no longer exists.
                    try:
                        DOCKER_CLIENT.inspect_container(name)
                    except Exception:
                        unregister_workload(name)
            except Exception:
                LOG.debug("lambda workload stop cleanup failed", exc_info=True)
        return result

    DockerRuntimeExecutor._get_networks_for_executor = _get_networks_for_executor
    DockerRuntimeExecutor.start = start
    DockerRuntimeExecutor.stop = stop


def _patch_vpc_endpoint() -> None:
    """Re-sync route tables after CreateVpcEndpoint installs prefix-list routes."""
    from moto.ec2.models.vpcs import VPCBackend
    from localemu.services.ec2.docker.vpc_routing import sync_route_table, sync_vpc

    original = VPCBackend.create_vpc_endpoint

    def create_vpc_endpoint(self, *args, **kwargs):
        endpoint = original(self, *args, **kwargs)
        try:
            account_id = str(getattr(self, "account_id", None) or "000000000000")
            region = str(getattr(self, "region_name", None) or "us-east-1")
            route_tables = list(getattr(endpoint, "route_table_ids", None) or [])
            vpc_id = getattr(endpoint, "vpc_id", None)
            for rtb in route_tables:
                sync_route_table(str(rtb), account_id, region)
            if vpc_id and not route_tables:
                sync_vpc(str(vpc_id), account_id, region)
        except Exception:
            LOG.warning("vpc route sync after CreateVpcEndpoint failed", exc_info=True)
        return endpoint

    VPCBackend.create_vpc_endpoint = create_vpc_endpoint


def _patch_container_restart() -> None:
    """Replay subnet routes after docker start (ECS resume / manual restart)."""
    from localemu.utils.docker_utils import DOCKER_CLIENT
    from localemu.services.ec2.docker.vpc_routing import (
        ensure_restart_watcher,
        replay_workload,
    )

    original = DOCKER_CLIENT.start_container

    def start_container(container_name_or_id, *args, **kwargs):
        result = original(container_name_or_id, *args, **kwargs)
        try:
            replay_workload(str(container_name_or_id))
        except Exception:
            LOG.debug(
                "vpc route replay after start %s failed",
                container_name_or_id,
                exc_info=True,
            )
        return result

    DOCKER_CLIENT.start_container = start_container
    ensure_restart_watcher()


_patch_routes()
_patch_launch()
_patch_nat_and_peering()
_patch_lambda()
_patch_vpc_endpoint()
_patch_container_restart()
LOG.info("awsbox vpc route enforcement installed")
