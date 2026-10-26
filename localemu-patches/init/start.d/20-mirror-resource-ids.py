"""Pin VPC, subnet, route table, and SG ids from the awsbox:resource-id tag.

`awsl apply` sends that tag so a synthetic fixture can round-trip the same
ids. Create calls without the tag keep moto's random ids.
"""

from __future__ import annotations

import logging
import re
import sys
import threading

LOG = logging.getLogger("localemu.awsbox.mirror_ids")
TAG = "awsbox:resource-id"
_LOCK = threading.Lock()
_ID = {
    "vpc": re.compile(r"^vpc-[0-9a-f]{8,17}$"),
    "subnet": re.compile(r"^subnet-[0-9a-f]{8,17}$"),
    "sg": re.compile(r"^sg-[0-9a-f]{8,17}$"),
    "rtb": re.compile(r"^rtb-[0-9a-f]{8,17}$"),
}


def _check(kind: str, value: str) -> str:
    if not _ID[kind].match(value):
        from moto.ec2.exceptions import GenericInvalidParameterValueError

        raise GenericInvalidParameterValueError(TAG, value)
    return value


def _list_tag(tags: list | None, kind: str) -> str | None:
    if not tags:
        return None
    for tag in tags:
        if isinstance(tag, dict) and tag.get("Key") == TAG and tag.get("Value"):
            return _check(kind, str(tag["Value"]))
    return None


def _nested_tag(tags: dict | None, bucket: str, kind: str) -> str | None:
    if not tags:
        return None
    inner = tags.get(bucket)
    if not isinstance(inner, dict):
        return None
    value = inner.get(TAG)
    if not value:
        return None
    return _check(kind, str(value))


def _flat_tag(tags: dict | None, kind: str) -> str | None:
    if not isinstance(tags, dict):
        return None
    value = tags.get(TAG)
    if not value:
        return None
    return _check(kind, str(value))


def _pin(module, fn_name: str, desired: str, call):
    with _LOCK:
        previous = getattr(module, fn_name)
        setattr(module, fn_name, lambda: desired)
        try:
            return call()
        finally:
            setattr(module, fn_name, previous)


def _install() -> None:
    import moto.ec2.models.route_tables as route_tables
    import moto.ec2.models.security_groups as security_groups
    import moto.ec2.models.subnets as subnets
    import moto.ec2.models.vpcs as vpcs

    orig_vpc = vpcs.VPCBackend.create_vpc
    orig_subnet = subnets.SubnetBackend.create_subnet
    orig_sg = security_groups.SecurityGroupBackend.create_security_group
    orig_rtb = route_tables.RouteBackend.create_route_table

    def create_vpc(self, *args, tags=None, **kwargs):
        desired = _list_tag(tags, "vpc")
        if not desired:
            return orig_vpc(self, *args, tags=tags, **kwargs)
        return _pin(
            vpcs,
            "random_vpc_id",
            desired,
            lambda: orig_vpc(self, *args, tags=tags, **kwargs),
        )

    def create_subnet(self, *args, tags=None, **kwargs):
        desired = _nested_tag(tags, "subnet", "subnet")
        if not desired:
            return orig_subnet(self, *args, tags=tags, **kwargs)
        return _pin(
            subnets,
            "random_subnet_id",
            desired,
            lambda: orig_subnet(self, *args, tags=tags, **kwargs),
        )

    def create_security_group(self, *args, tags=None, **kwargs):
        desired = _flat_tag(tags, "sg")
        if not desired:
            return orig_sg(self, *args, tags=tags, **kwargs)
        return _pin(
            security_groups,
            "random_security_group_id",
            desired,
            lambda: orig_sg(self, *args, tags=tags, **kwargs),
        )

    def create_route_table(self, *args, **kwargs):
        # moto may pass tags positionally (vpc_id, tags) or as kwargs.
        tags = kwargs.get("tags")
        if tags is None and len(args) >= 2 and isinstance(args[1], list):
            tags = args[1]
        desired = _list_tag(tags, "rtb")
        if not desired:
            return orig_rtb(self, *args, **kwargs)
        return _pin(
            route_tables,
            "random_route_table_id",
            desired,
            lambda: orig_rtb(self, *args, **kwargs),
        )

    vpcs.VPCBackend.create_vpc = create_vpc
    subnets.SubnetBackend.create_subnet = create_subnet
    security_groups.SecurityGroupBackend.create_security_group = create_security_group
    route_tables.RouteBackend.create_route_table = create_route_table
    LOG.info("awsbox mirror resource-id pin enabled")
    print("awsbox mirror resource-id pin enabled", file=sys.stderr, flush=True)


_install()
