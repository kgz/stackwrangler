"""Interface VPC endpoint private DNS for in-VPC workloads.

Answers A records for the regional service hostnames (sts / logs / ssm /
ecs / ecr.api / ecr.dkr) with the endpoint proxy IP when the VPC has an
Interface endpoint with ``PrivateDnsEnabled``. Everything else is forwarded.

The process (root, UDP/TCP 53) is shared with the Route 53 private-zone
resolver: ``serve`` runs ``r53_private_resolver`` when it is mounted, which
calls back into ``_lookup`` here. Wire codec, docker address discovery and
the UDP/TCP servers live in ``dns_common`` (``awsbox_dns_common``).
"""

from __future__ import annotations

import ipaddress
import logging
import os
import sys
import threading
import time

if "/opt/awsbox/dns" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/dns")

import awsbox_dns_common as dns  # noqa: E402
from awsbox_dns_common import (  # noqa: E402,F401
    A as _A,
    AAAA as _AAAA,
    dns_server_ip_for_subnet,
    dns_server_ip_for_vpc,
    a_rdata as _a_rdata,
    boto as _boto,
    norm as _norm,
)

LOG = logging.getLogger("awsbox.vpce.dns")

_API_LOCK = threading.Lock()
_API_AT = 0.0
# vpc_id → list of {hosts: set[str], wildcards: list[str], ip: str, endpoint_id: str}
_ENDPOINTS: dict[str, list[dict]] = {}
_API_OK = False


def service_hostnames(service_name: str) -> tuple[set[str], list[str]]:
    """Return (exact hostnames, wildcard suffixes) for a VPCE service name."""
    parts = [p for p in service_name.split(".") if p]
    hosts: set[str] = set()
    wildcards: list[str] = []
    # com.amazonaws.<region>.<service…>
    if len(parts) >= 4 and parts[0] == "com" and parts[1] == "amazonaws":
        region = parts[2]
        rest = parts[3:]
        if rest == ["ecr", "api"]:
            hosts.add(f"api.ecr.{region}.amazonaws.com")
        elif rest == ["ecr", "dkr"]:
            hosts.add(f"dkr.ecr.{region}.amazonaws.com")
            wildcards.append(f".dkr.ecr.{region}.amazonaws.com")
        elif len(rest) == 1:
            hosts.add(f"{rest[0]}.{region}.amazonaws.com")
        else:
            hosts.add(".".join(rest + [region, "amazonaws", "com"]))
    return hosts, wildcards


def _looks_like_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return False
    return True


def _proxy_ip_from_entries(entries: list[dict]) -> str | None:
    for entry in entries or []:
        name = str(entry.get("DnsName") or entry.get("dns_name") or "")
        # Strip accidental :port from older localemu entries.
        host = name.split(":")[0]
        if _looks_like_ip(host):
            return host
    return None


def _proxy_ip_from_docker(endpoint_id: str, vpc_id: str) -> str | None:
    try:
        client = dns.docker_client()
        name = f"localemu-vpce-{endpoint_id}"
        ctr = client.containers.get(name)
        nets = ((ctr.attrs or {}).get("NetworkSettings") or {}).get("Networks") or {}
        info = nets.get(f"localemu-vpc-{vpc_id}") or {}
        addr = str(info.get("IPAddress") or "").split("/")[0]
        return addr or None
    except Exception:
        return None


def _refresh_api(force: bool = False) -> None:
    global _API_AT, _ENDPOINTS, _API_OK
    now = time.time()
    if not force and _API_OK and now - _API_AT < 1.0:
        return
    with _API_LOCK:
        now = time.time()
        if not force and _API_OK and now - _API_AT < 1.0:
            return
        try:
            ec2 = _boto("ec2")
            pages = ec2.get_paginator("describe_vpc_endpoints").paginate()
            by_vpc: dict[str, list[dict]] = {}
            for page in pages:
                for ep in page.get("VpcEndpoints") or []:
                    if str(ep.get("VpcEndpointType") or "").lower() != "interface":
                        continue
                    if not ep.get("PrivateDnsEnabled"):
                        continue
                    vpc_id = str(ep.get("VpcId") or "")
                    endpoint_id = str(ep.get("VpcEndpointId") or "")
                    service = str(ep.get("ServiceName") or "")
                    if not vpc_id or not endpoint_id or not service:
                        continue
                    hosts, wildcards = service_hostnames(service)
                    if not hosts and not wildcards:
                        continue
                    ip = _proxy_ip_from_entries(ep.get("DnsEntries") or [])
                    if not ip:
                        ip = _proxy_ip_from_docker(endpoint_id, vpc_id)
                    if not ip:
                        continue
                    by_vpc.setdefault(vpc_id, []).append(
                        {
                            "hosts": {_norm(h) for h in hosts},
                            "wildcards": [_norm(w).lstrip(".") for w in wildcards],
                            "ip": ip,
                            "endpoint_id": endpoint_id,
                            "service": service,
                        }
                    )
            _ENDPOINTS = by_vpc
            _API_AT = time.time()
            _API_OK = True
            LOG.info(
                "vpce private dns endpoints=%s",
                {
                    vpc: [
                        (row["service"], row["ip"], sorted(row["hosts"]))
                        for row in rows
                    ]
                    for vpc, rows in by_vpc.items()
                },
            )
        except Exception as exc:
            text = str(exc)
            if "Could not connect" in text or "Connection refused" in text:
                LOG.info("ec2 API not ready yet")
            else:
                LOG.warning("describe_vpc_endpoints failed: %s", text)


def _match_endpoint(qname: str, vpc_id: str | None) -> dict | None:
    if not vpc_id:
        return None
    _refresh_api()
    name = _norm(qname)
    for row in _ENDPOINTS.get(vpc_id) or []:
        if name in row["hosts"]:
            return row
        for suffix in row["wildcards"]:
            # suffix is like "dkr.ecr.us-east-1.amazonaws.com"
            if name == suffix or name.endswith("." + suffix):
                return row
    return None


def _lookup(qname: str, qtype: int, vpc_id: str | None) -> tuple[int, list[tuple[str, int, int, bytes]]] | None:
    row = _match_endpoint(qname, vpc_id)
    if row is None:
        # Other VPCs (or no VPC) fall through to public DNS — same as AWS when
        # the private hosted zone is not associated with that VPC.
        return None
    if qtype == _AAAA:
        return 0, []
    if qtype not in {_A, 255}:
        return 0, []
    return 0, [(_norm(qname), _A, 60, _a_rdata(row["ip"]))]


def _answer(qname: str, qtype: int, vpc_id: str | None, _local_ip: str | None) -> dns.Answer | None:
    found = _lookup(qname, qtype, vpc_id)
    if found is None:
        return None
    return dns.Answer(found[0], found[1])


_R53_PATH = "/opt/code/localemu/src/localemu/services/route53/private_resolver.py"


def serve() -> None:
    # One process owns UDP/TCP 53 on each VPC address; the Route 53 resolver
    # answers private hosted zones, then falls back to this module's endpoints.
    if os.path.isfile(_R53_PATH):
        import runpy

        logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
        LOG.info("VPCE private DNS resolver starting")
        runpy.run_path(_R53_PATH, run_name="awsbox_r53_serve")["serve"]()
        return
    dns.serve(_answer, "VPCE private DNS resolver")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "serve":
        serve()
