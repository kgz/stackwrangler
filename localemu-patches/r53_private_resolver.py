"""Private hosted-zone resolver for VPC workloads.

Runs as its own process (root, UDP/TCP 53) so it can bind port 53 after
the gateway drops capabilities. Answers are scoped by the destination
IP: each VPC's Docker network has this container's address, and workloads
are started with ``--dns`` set to that address. A query arriving on
VPC A's address only sees zones associated with VPC A.

A/AAAA/CNAME come from Route 53. Alias and ``*.elb.amazonaws.com`` names
synthesize an A record for this container's address on that VPC network,
where the ELBv2 listener (elbv2_listener_router) is bound.

Interface endpoint names (vpce_private_dns) are answered here too, since
only one process can own port 53 on the VPC address.
"""

from __future__ import annotations

import logging
import os
import select
import socket
import struct
import threading
import time

LOG = logging.getLogger("awsbox.r53")

_A = 1
_NS = 2
_CNAME = 5
_SOA = 6
_AAAA = 28
_IN = 1
_NXDOMAIN = 3
_SERVFAIL = 2
_FORMERR = 1

_CONNECT_LOCK = threading.Lock()
_SELF_IPS: dict[str, str] = {}
_SELF_IPS_AT = 0.0
_DOCKER = None

_API_LOCK = threading.Lock()
_API_AT = 0.0
_ZONES: list[dict] = []
_LBS: list[dict] = []
_API_OK = False
_API_SIG = ""


def _hostname() -> str:
    try:
        return open("/etc/hostname", encoding="utf-8").read().strip()
    except OSError:
        return socket.gethostname()


def _docker():
    global _DOCKER
    if _DOCKER is None:
        import docker

        _DOCKER = docker.from_env()
    return _DOCKER


def dns_server_ip_for_vpc(vpc_id: str) -> str | None:
    """Attach this container to the VPC bridge and return its address there."""
    if not vpc_id:
        return None
    with _CONNECT_LOCK:
        try:
            client = _docker()
        except Exception:
            LOG.warning("docker client unavailable; private DNS disabled", exc_info=True)
            return None
        name = f"localemu-vpc-{vpc_id}"
        try:
            net = client.networks.get(name)
        except Exception:
            LOG.info("VPC network %s does not exist yet", name)
            return None
        cid = _hostname()
        try:
            net.connect(cid)
        except Exception:
            pass
        try:
            net.reload()
        except Exception:
            LOG.warning("could not inspect %s", name, exc_info=True)
            return None
        containers = (net.attrs or {}).get("Containers") or {}
        for full_id, info in containers.items():
            if not (full_id.startswith(cid) or str(info.get("Name") or "").startswith(cid)):
                continue
            addr = str(info.get("IPv4Address") or "").split("/")[0]
            if addr:
                _SELF_IPS[addr] = vpc_id
                return addr
        return None


def dns_server_ip_for_subnet(subnet_id: str, account_id: str, region: str) -> str | None:
    if not subnet_id:
        return None
    try:
        from localemu.services.ec2.docker.vpc_network import get_vpc_network_manager
    except Exception:
        return None
    vpcm = get_vpc_network_manager()
    accounts: list[str] = []
    if account_id:
        accounts.append(account_id)
    if "000000000000" not in accounts:
        accounts.append("000000000000")
    vpc_id = None
    for acct in accounts:
        try:
            vpc_id = vpcm.get_vpc_id_for_subnet(subnet_id, acct, region)
        except Exception:
            vpc_id = None
        if vpc_id:
            break
    if not vpc_id:
        return None
    return dns_server_ip_for_vpc(vpc_id)


def _refresh_self_ips(force: bool = False) -> None:
    global _SELF_IPS_AT
    now = time.time()
    if not force and now - _SELF_IPS_AT < 1.0 and _SELF_IPS:
        return
    try:
        client = _docker()
        cid = _hostname()
        mapping: dict[str, str] = {}
        for net in client.networks.list():
            name = net.name or ""
            if not name.startswith("localemu-vpc-"):
                continue
            try:
                net.reload()
            except Exception:
                continue
            vpc_id = name[len("localemu-vpc-") :]
            containers = (net.attrs or {}).get("Containers") or {}
            for full_id, info in containers.items():
                if not full_id.startswith(cid):
                    continue
                addr = str(info.get("IPv4Address") or "").split("/")[0]
                if addr:
                    mapping[addr] = vpc_id
        if mapping:
            _SELF_IPS.clear()
            _SELF_IPS.update(mapping)
        _SELF_IPS_AT = now
    except Exception:
        LOG.debug("self-ip refresh failed", exc_info=True)


def _norm(name: str) -> str:
    return name.strip().rstrip(".").lower()


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


def _access_key() -> str:
    raw = os.environ.get("ROOT_ACCESS_KEYS") or "awsbox"
    return raw.split(",")[0].strip() or "awsbox"


def _secret_key() -> str:
    return os.environ.get("R53_RESOLVER_SECRET") or os.environ.get("AWSBOX_SECRET_KEY") or "awsboxawsbox"


def _boto(service: str):
    import boto3
    from botocore.config import Config

    cfg = Config(connect_timeout=2, read_timeout=8, retries={"max_attempts": 2})
    return boto3.client(
        service,
        endpoint_url="http://127.0.0.1:4566",
        region_name=os.environ.get("AWS_DEFAULT_REGION") or "us-east-1",
        aws_access_key_id=_access_key(),
        aws_secret_access_key=_secret_key(),
        config=cfg,
    )


def _zone_id_token(zone_id: str) -> str:
    return zone_id.rstrip("/").split("/")[-1]


def _docker_vpc_ids() -> list[str]:
    try:
        client = _docker()
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
        try:
            resp = r53.list_hosted_zones_by_vpc(VPCId=vpc_id, VPCRegion=region)
        except Exception:
            LOG.debug("list-hosted-zones-by-vpc failed for %s", vpc_id, exc_info=True)
            continue
        for summary in resp.get("HostedZoneSummaries") or []:
            if _zone_id_token(str(summary.get("HostedZoneId") or "")) == want:
                found.add(vpc_id)
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
            listed = r53.list_hosted_zones().get("HostedZones") or []
            for zone in listed:
                private = bool((zone.get("Config") or {}).get("PrivateZone"))
                if not private:
                    continue
                detail = r53.get_hosted_zone(Id=zone["Id"])
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
                        "vpcs": vpcs,
                        "records": _list_records(r53, zone["Id"]),
                    }
                )
            lbs = elb.describe_load_balancers().get("LoadBalancers") or []
            _ZONES = zones
            _LBS = lbs
            _API_AT = time.time()
            _API_OK = True
            sig = repr(
                (
                    [(z["name"], sorted(z["vpcs"])) for z in zones],
                    [str(lb.get("DNSName") or "") for lb in lbs],
                )
            )
            if sig != _API_SIG:
                _API_SIG = sig
                LOG.info(
                    "route53 zones=%s lbs=%s",
                    [(z["name"], sorted(z["vpcs"])) for z in zones],
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


def _write_name(name: str) -> bytes:
    out = b""
    for label in _norm(name).split("."):
        if not label:
            continue
        raw = label.encode("ascii")
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def _read_name(data: bytes, offset: int) -> tuple[str, int]:
    labels: list[str] = []
    jumped = False
    end = offset
    seen = 0
    while seen < 32 and offset < len(data):
        length = data[offset]
        if length == 0:
            offset += 1
            if not jumped:
                end = offset
            break
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(data):
                break
            ptr = ((length & 0x3F) << 8) | data[offset + 1]
            if not jumped:
                end = offset + 2
            offset = ptr
            jumped = True
            seen += 1
            continue
        offset += 1
        labels.append(data[offset : offset + length].decode("ascii", "replace"))
        offset += length
        if not jumped:
            end = offset
        seen += 1
    return ".".join(labels), end


def _flags(rd: bool, rcode: int) -> int:
    base = 0x8480
    if rd:
        base |= 0x0100
    return base | (rcode & 0xF)


def _pack(tid: int, rd: bool, question: bytes, rcode: int, rrs: list[tuple[str, int, int, bytes]]) -> bytes:
    header = struct.pack("!HHHHHH", tid, _flags(rd, rcode), 1, len(rrs), 0, 0)
    body = question
    for name, typ, ttl, rdata in rrs:
        body += _write_name(name) + struct.pack("!HHIH", typ, _IN, ttl, len(rdata)) + rdata
    return header + body


def _parse(data: bytes) -> tuple[int, bool, str, int, bytes] | None:
    if len(data) < 12:
        return None
    tid, flags = struct.unpack("!HH", data[:4])
    rd = bool(flags & 0x0100)
    try:
        qname, off = _read_name(data, 12)
    except Exception:
        return None
    if off + 4 > len(data):
        return None
    qtype, _qclass = struct.unpack("!HH", data[off : off + 4])
    return tid, rd, qname, qtype, data[12 : off + 4]


def _a_rdata(ip: str) -> bytes:
    return socket.inet_aton(ip)


def _aaaa_rdata(ip: str) -> bytes:
    return socket.inet_pton(socket.AF_INET6, ip)


def _lb_by_name(name: str) -> dict | None:
    want = _norm(name)
    for lb in _LBS:
        if _norm(str(lb.get("DNSName") or "")) == want:
            return lb
    return None


class _Answer:
    def __init__(self, rcode: int, rrs: list[tuple[str, int, int, bytes]]):
        self.rcode = rcode
        self.rrs = rrs


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


def _lookup(qname: str, qtype: int, vpc_id: str | None, local_ip: str | None, depth: int = 0) -> _Answer | None:
    _refresh_api()
    name = _norm(qname)
    matching = [zone for zone in _ZONES if _name_in_zone(name, zone["name"])]
    if matching:
        associated = [zone for zone in matching if vpc_id and vpc_id in zone["vpcs"]]
        if not associated:
            return _Answer(_NXDOMAIN, [])
        associated.sort(key=lambda zone: len(zone["name"]), reverse=True)
        for zone in associated:
            named = [rec for rec in zone["records"] if _norm(str(rec.get("Name") or "")) == name]
            if not named:
                continue
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
        return _Answer(_NXDOMAIN, [])
    lb = _lb_by_name(name)
    if lb is not None:
        return _elb_answer(lb, vpc_id, qtype, local_ip)
    return _vpce_answer(name, qtype, vpc_id)


def _forward(payload: bytes) -> bytes | None:
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(2)
        sock.sendto(payload, ("8.8.8.8", 53))
        data, _addr = sock.recvfrom(4096)
        sock.close()
        return data
    except OSError:
        return None


def _handle(payload: bytes, vpc_id: str | None, local_ip: str | None) -> bytes | None:
    parsed = _parse(payload)
    if parsed is None:
        if len(payload) >= 2:
            tid = struct.unpack("!H", payload[:2])[0]
            return _pack(tid, False, b"\x00" + struct.pack("!HH", _A, _IN), _FORMERR, [])
        return None
    tid, rd, qname, qtype, question = parsed
    try:
        answer = _lookup(qname, qtype, vpc_id, local_ip)
    except Exception:
        LOG.warning("lookup failed for %s", qname, exc_info=True)
        return _pack(tid, rd, question, _SERVFAIL, [])
    if answer is None:
        forwarded = _forward(payload)
        if forwarded is not None:
            return forwarded
        return _pack(tid, rd, question, _SERVFAIL, [])
    if answer.rcode == 0 and answer.rrs:
        LOG.info("answer %s type=%s vpc=%s -> %s rr", qname, qtype, vpc_id, len(answer.rrs))
    elif answer.rcode == _NXDOMAIN:
        LOG.info("nxdomain %s vpc=%s", qname, vpc_id)
    return _pack(tid, rd, question, answer.rcode, answer.rrs)


def _recv_exact(conn: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def _tcp_server() -> None:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    while True:
        try:
            sock.bind(("0.0.0.0", 53))
            break
        except OSError:
            LOG.warning("TCP/53 bind failed; retrying")
            time.sleep(1)
    sock.listen(32)
    LOG.info("private DNS TCP/53")
    while True:
        try:
            conn, addr = sock.accept()
        except OSError:
            time.sleep(0.2)
            continue
        threading.Thread(target=_tcp_client, args=(conn, addr[0]), daemon=True).start()


def _tcp_client(conn: socket.socket, src: str) -> None:
    del src
    try:
        conn.settimeout(5)
        header = _recv_exact(conn, 2)
        if len(header) < 2:
            return
        length = struct.unpack("!H", header)[0]
        payload = _recv_exact(conn, length)
        local_ip = conn.getsockname()[0]
        _refresh_self_ips()
        vpc_id = _SELF_IPS.get(local_ip)
        if vpc_id is None:
            _refresh_self_ips(force=True)
            vpc_id = _SELF_IPS.get(local_ip)
        response = _handle(payload, vpc_id, local_ip if vpc_id else None)
        if response:
            conn.sendall(struct.pack("!H", len(response)) + response)
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def _ensure_udp(bound: dict[str, socket.socket]) -> None:
    _refresh_self_ips()
    for ip in list(_SELF_IPS):
        if ip in bound:
            continue
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((ip, 53))
        except OSError:
            sock.close()
            LOG.debug("UDP/53 not bound on %s yet", ip)
            continue
        sock.setblocking(False)
        bound[ip] = sock
        LOG.info("private DNS UDP/53 on %s vpc=%s", ip, _SELF_IPS.get(ip))
    for ip in list(bound):
        if ip not in _SELF_IPS:
            try:
                bound.pop(ip).close()
            except OSError:
                pass


def _udp_loop() -> None:
    bound: dict[str, socket.socket] = {}
    while True:
        _ensure_udp(bound)
        if not bound:
            time.sleep(0.4)
            continue
        socks = list(bound.values())
        try:
            ready, _, _ = select.select(socks, [], [], 0.4)
        except (OSError, ValueError):
            time.sleep(0.2)
            continue
        for sock in ready:
            try:
                payload, addr = sock.recvfrom(4096)
            except OSError:
                continue
            local_ip = sock.getsockname()[0]
            vpc_id = _SELF_IPS.get(local_ip)
            try:
                response = _handle(payload, vpc_id, local_ip)
            except Exception:
                LOG.warning("udp query failed", exc_info=True)
                continue
            if not response:
                continue
            try:
                sock.sendto(response, addr)
            except OSError:
                LOG.debug("udp send failed", exc_info=True)


def serve() -> None:
    import signal

    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    os.environ["AWS_EC2_METADATA_DISABLED"] = "true"
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    LOG.info("private DNS resolver starting")
    threading.Thread(target=_tcp_server, name="r53-tcp", daemon=True).start()
    _udp_loop()


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "serve":
        serve()
