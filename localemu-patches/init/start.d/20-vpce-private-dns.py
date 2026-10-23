"""Point EC2 / VPC Lambda at the Interface-endpoint private DNS resolver.

Also enrich CreateVpcEndpoint DnsEntries with the regional service hostname
when PrivateDnsEnabled is true.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.vpce_dns")


def _patch_ec2_dns() -> None:
    import localemu.services.ec2.docker.vpc_dns as vpc_dns

    original = vpc_dns.resolve_vpc_dns_servers

    def resolve_vpc_dns_servers(
        *,
        subnet_id,
        account_id,
        region,
        drop_amazon_provided_dns=True,
    ):
        servers = list(
            original(
                subnet_id=subnet_id,
                account_id=account_id,
                region=region,
                drop_amazon_provided_dns=drop_amazon_provided_dns,
            )
        )
        ip = None
        try:
            from localemu.services.ec2.docker.vpce_private_dns import (
                dns_server_ip_for_subnet,
            )

            ip = dns_server_ip_for_subnet(subnet_id or "", account_id or "", region or "")
        except Exception:
            LOG.warning("EC2 VPCE private DNS lookup failed", exc_info=True)
        if ip and ip not in servers:
            servers.insert(0, ip)
        return servers

    vpc_dns.resolve_vpc_dns_servers = resolve_vpc_dns_servers


def _patch_lambda_dns() -> None:
    from localemu import config as le_config
    from localemu.services.lambda_.invocation.docker_runtime_executor import (
        DockerRuntimeExecutor,
    )

    original = DockerRuntimeExecutor._do_start

    def _dns_ip(self) -> str | None:
        vpc = getattr(self.function_version.config, "vpc_config", None)
        if vpc is None:
            return None
        vpc_id = getattr(vpc, "vpc_id", None)
        if not vpc_id:
            return None
        try:
            from localemu.services.ec2.docker.vpce_private_dns import dns_server_ip_for_vpc

            return dns_server_ip_for_vpc(vpc_id)
        except Exception:
            LOG.warning("Lambda VPCE private DNS lookup failed", exc_info=True)
            return None

    def _do_start(self, env_vars):
        dns_ip = _dns_ip(self)
        previous = le_config.LAMBDA_DOCKER_FLAGS
        try:
            if dns_ip:
                extra = f"--dns {dns_ip}"
                le_config.LAMBDA_DOCKER_FLAGS = (
                    f"{previous} {extra}".strip() if previous else extra
                )
            original(self, env_vars)
        finally:
            le_config.LAMBDA_DOCKER_FLAGS = previous
        if not dns_ip:
            return
        try:
            import docker

            client = docker.from_env()
            client.containers.get(self.container_name).exec_run(
                ["sh", "-c", f"printf 'nameserver {dns_ip}\\n' > /etc/resolv.conf"],
            )
        except Exception:
            LOG.debug("Lambda resolv.conf update failed", exc_info=True)

    DockerRuntimeExecutor._do_start = _do_start


_patch_ec2_dns()
_patch_lambda_dns()
LOG.info("VPCE private DNS hooks installed for EC2 and Lambda")
