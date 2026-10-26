"""Route 53 hosted-zone resolver for VPC workloads (and loopback dig).

Runs as its own process (root, UDP/TCP 53) so it can bind port 53 after
the gateway drops capabilities. Answers are scoped by the destination
IP: each VPC's Docker network has this container's address, and workloads
are started with ``--dns`` set to that address. A query arriving on
VPC A's address only sees **private** zones associated with VPC A.
**Public** hosted zones answer on every VPC address and on loopback
(``127.0.0.1``) so ``dig @127.0.0.1`` from inside the emulator works.

A/AAAA/CNAME come from Route 53. Alias and ``*.elb.amazonaws.com`` names
synthesize an A record for this container's address on that VPC network,
where the ELBv2 listener (elbv2_listener_router) is bound.

Interface endpoint names (vpce_private_dns) are answered here too, since
only one process can own port 53 on the VPC address.
"""

from __future__ import annotations

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
    CNAME as _CNAME,
    NS as _NS,
    NXDOMAIN as _NXDOMAIN,
    SERVFAIL as _SERVFAIL,
    SOA as _SOA,
    Answer as _Answer,
    a_rdata as _a_rdata,
    aaaa_rdata as _aaaa_rdata,
    boto as _boto,
    dns_server_ip_for_subnet,
    dns_server_ip_for_vpc,
    norm as _norm,
    write_name as _write_name,
)

LOG = logging.getLogger("awsbox.r53")

_API_LOCK = threading.Lock()
_API_AT = 0.0
_ZONES: list[dict] = []
_LBS: list[dict] = []
_API_OK = False
_API_SIG = ""


def _qtype_name(qtype: int) -> str:
    return { _A: "A", _NS: "NS", _CNAME: "CNAME", _SOA: "SOA", _AAAA: "AAAA" }.get(qtype, "")


def _rr_values(record: dict) -> list[str]:
    out: list[str] = []
    for item in record.get("ResourceRecords") or []:
        if isinstance(item, str):
            out.append(item)
        elif isinstance(item, dict) and item.get("Value"):
            out.append(str(item["Value"]))
    return out


def _zone_id_token(zone_id: str) -> str:
    return zone_id.rstrip("/").split("/")[-1]


def _docker_vpc_ids() -> list[str]:
    try:
        client = dns.docker_client()
    except Exception:
        return []
    found: list[str] = []
    for net in client.networks.list():
        name = net.name or ""
        if name.startswith("localemu-vpc-"):
            found.append(name[len("localemu-vpc-") :])
    return found


def _vpcs_via_list(r53, zone_id: str) -> set[str]:
    want = _zone_id_token(zone_id)
    region = os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
    found: set[str] = set()
    for vpc_id in _docker_vpc_ids():
        kwargs: dict = {"VPCId": vpc_id, "VPCRegion": region}
        while True:
            try:
                resp = r53.list_hosted_zones_by_vpc(**kwargs)
            except Exception:
                LOG.debug("list-hosted-zones-by-vpc failed for %s", vpc_id, exc_info=True)
                break
            for summary in resp.get("HostedZoneSummaries") or []:
                if _zone_id_token(str(summary.get("HostedZoneId") or "")) == want:
                    found.add(vpc_id)
            token = resp.get("NextToken")
            if not token:
                break
            kwargs["NextToken"] = token
    return found


def _list_records(r53, zone_id: str) -> list[dict]:
    kwargs: dict = {"HostedZoneId": zone_id}
    out: list[dict] = []
    while True:
        page = r53.list_resource_record_sets(**kwargs)
        out.extend(page.get("ResourceRecordSets") or [])
        if not page.get("IsTruncated"):
            return out
        kwargs["StartRecordName"] = page["NextRecordName"]
        kwargs["StartRecordType"] = page["NextRecordType"]
        ident = page.get("NextRecordIdentifier")
        if ident:
            kwargs["StartRecordIdentifier"] = ident


def _refresh_api(force: bool = False) -> None:
    global _API_AT, _ZONES, _LBS, _API_OK, _API_SIG
    now = time.time()
    if not force and _API_OK and now - _API_AT < 1.0:
        return
    with _API_LOCK:
        now = time.time()
        if not force and _API_OK and now - _API_AT < 1.0:
            return
        try:
            r53 = _boto("route53")
            elb = _boto("elbv2")
            zones: list[dict] = []
            listed = [
                zone
                for page in r53.get_paginator("list_hosted_zones").paginate()
                for zone in page.get("HostedZones") or []
            ]
            for zone in listed:
                private = bool((zone.get("Config") or {}).get("PrivateZone"))
                detail = r53.get_hosted_zone(Id=zone["Id"])
                vpcs: set[str] = set()
                if private:
                    vpcs = {
                        str(item.get("VPCId"))
                        for item in (detail.get("VPCs") or [])
                        if item.get("VPCId")
                    }
                    if not vpcs:
                        vpcs = _vpcs_via_list(r53, zone["Id"])
                zones.append(
                    {
                        "name": _norm(str(zone.get("Name") or "")),
                        "private": private,
                        "vpcs": vpcs,
                        "records": _list_records(r53, zone["Id"]),
                    }
                )
            lbs = [
                lb
                for page in elb.get_paginator("describe_load_balancers").paginate()
                for lb in page.get("LoadBalancers") or []
            ]
            _ZONES = zones
            _LBS = lbs
            _API_AT = time.time()
            _API_OK = True
            sig = repr(
                (
                    [
                        (z["name"], z.get("private"), sorted(z["vpcs"]))
                        for z in zones
                    ],
                    [str(lb.get("DNSName") or "") for lb in lbs],
                )
            )
            if sig != _API_SIG:
                _API_SIG = sig
                LOG.info(
                    "route53 zones=%s lbs=%s",
                    [
                        (z["name"], "private" if z.get("private") else "public", sorted(z["vpcs"]))
                        for z in zones
                    ],
                    [str(lb.get("DNSName") or "") for lb in lbs],
                )
        except Exception as exc:
            text = str(exc)
            if "Could not connect" in text or "Connection refused" in text:
                LOG.info("route53 API not ready yet")
            else:
                LOG.warning("route53/elbv2 refresh failed: %s", text)


def _name_in_zone(qname: str, zone: str) -> bool:
    return qname == zone or qname.endswith("." + zone)


def _lb_by_name(name: str) -> dict | None:
    want = _norm(name)
    for lb in _LBS:
        if _norm(str(lb.get("DNSName") or "")) == want:
            return lb
    return None


def _elb_answer(lb: dict, vpc_id: str | None, qtype: int, local_ip: str | None) -> _Answer:
    scheme = str(lb.get("Scheme") or "internet-facing")
    lb_vpc = str(lb.get("VpcId") or "")
    if scheme == "internal" and vpc_id != lb_vpc:
        return _Answer(_NXDOMAIN, [])
    if qtype == _AAAA:
        return _Answer(0, [])
    if qtype not in {_A, 255}:
        return _Answer(0, [])
    ip = local_ip if vpc_id and local_ip else None
    if ip is None and lb_vpc:
        ip = dns_server_ip_for_vpc(lb_vpc)
    if not ip:
        return _Answer(_SERVFAIL, [])
    return _Answer(0, [(_norm(str(lb.get("DNSName") or "")), _A, 60, _a_rdata(ip))])


def _follow(name: str, qtype: int, vpc_id: str | None, local_ip: str | None, depth: int) -> _Answer | None:
    if depth > 6:
        return _Answer(0, [])
    return _lookup(_norm(name), qtype, vpc_id, local_ip, depth)


def _record_answer(
    record: dict,
    qname: str,
    qtype: int,
    vpc_id: str | None,
    local_ip: str | None,
    depth: int,
) -> _Answer | None:
    alias = record.get("AliasTarget") or {}
    if isinstance(alias, dict) and alias.get("DNSName"):
        if qtype not in {_A, _AAAA, 255}:
            return None
        followed = _follow(str(alias["DNSName"]), qtype if qtype != 255 else _A, vpc_id, local_ip, depth + 1)
        if followed is None:
            return _Answer(_NXDOMAIN, [])
        rewritten: list[tuple[str, int, int, bytes]] = []
        for _name, typ, ttl, rdata in followed.rrs:
            if typ == _CNAME:
                continue
            rewritten.append((qname, typ, ttl, rdata))
        if not rewritten and followed.rcode == 0:
            return _Answer(0, [])
        return _Answer(followed.rcode, rewritten or followed.rrs)

    typ = str(record.get("Type") or "")
    ttl = int(record.get("TTL") or 60)
    values = _rr_values(record)
    if typ == "CNAME" and values and qtype in {_A, _AAAA, _CNAME, 255}:
        target = values[0]
        rrs = [(qname, _CNAME, ttl, _write_name(target))]
        if qtype == _CNAME:
            return _Answer(0, rrs)
        followed = _follow(target, qtype if qtype != 255 else _A, vpc_id, local_ip, depth + 1)
        if followed is not None:
            rrs.extend(followed.rrs)
        return _Answer(0, rrs)
    want = _qtype_name(qtype)
    if typ != want or not values:
        return None
    rrs = []
    for value in values:
        try:
            if typ == "A":
                rdata = _a_rdata(value)
            elif typ == "AAAA":
                rdata = _aaaa_rdata(value)
            elif typ in {"CNAME", "NS"}:
                rdata = _write_name(value)
            else:
                continue
        except OSError:
            continue
        rrs.append((qname, qtype, ttl, rdata))
    if not rrs:
        return None
    return _Answer(0, rrs)


_VPCE_PATH = "/opt/code/localemu/src/localemu/services/ec2/docker/vpce_private_dns.py"
_VPCE = None


def _vpce_module():
    global _VPCE
    if _VPCE is not None:
        return _VPCE or None
    _VPCE = False
    if not os.path.isfile(_VPCE_PATH):
        return None
    try:
        import importlib.util

        spec = importlib.util.spec_from_file_location("awsbox_vpce_dns", _VPCE_PATH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _VPCE = module
    except Exception:
        LOG.warning("VPCE private DNS module failed to load", exc_info=True)
    return _VPCE or None


def _vpce_answer(name: str, qtype: int, vpc_id: str | None) -> _Answer | None:
    module = _vpce_module()
    if module is None:
        return None
    answer = module._lookup(name, qtype, vpc_id)
    if answer is None:
        return None
    return _Answer(answer[0], answer[1])


def _zones_for_query(matching: list[dict], vpc_id: str | None) -> list[dict]:
    """Private zones need VPC association; public zones answer everywhere."""
    private_ok = [
        zone
        for zone in matching
        if zone.get("private") and vpc_id and vpc_id in zone["vpcs"]
    ]
    public = [zone for zone in matching if not zone.get("private")]
    # Prefer the longest associated private zone, then public.
    chosen = private_ok or public
    chosen.sort(key=lambda zone: len(zone["name"]), reverse=True)
    return chosen


def _answer_from_zone(
    zone: dict,
    name: str,
    qtype: int,
    vpc_id: str | None,
    local_ip: str | None,
    depth: int,
) -> _Answer | None:
    named = [rec for rec in zone["records"] if _norm(str(rec.get("Name") or "")) == name]
    if not named:
        return None
    for rec in named:
        if rec.get("AliasTarget"):
            answer = _record_answer(rec, name, qtype, vpc_id, local_ip, depth)
            if answer is not None:
                return answer
    for rec in named:
        if str(rec.get("Type") or "") == "CNAME":
            answer = _record_answer(rec, name, qtype, vpc_id, local_ip, depth)
            if answer is not None:
                return answer
    for rec in named:
        answer = _record_answer(rec, name, qtype, vpc_id, local_ip, depth)
        if answer is not None:
            return answer
    return _Answer(0, [])


def _lookup(qname: str, qtype: int, vpc_id: str | None, local_ip: str | None, depth: int = 0) -> _Answer | None:
    _refresh_api()
    name = _norm(qname)
    matching = [zone for zone in _ZONES if _name_in_zone(name, zone["name"])]
    if matching:
        chosen = _zones_for_query(matching, vpc_id)
        if not chosen:
            # Only private zones matched, none associated with this VPC.
            return _Answer(_NXDOMAIN, [])
        for zone in chosen:
            answer = _answer_from_zone(zone, name, qtype, vpc_id, local_ip, depth)
            if answer is not None:
                return answer
        return _Answer(_NXDOMAIN, [])
    lb = _lb_by_name(name)
    if lb is not None:
        return _elb_answer(lb, vpc_id, qtype, local_ip)
    return _vpce_answer(name, qtype, vpc_id)


def serve() -> None:
    dns.serve(_lookup, "private DNS resolver")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "serve":
        serve()
