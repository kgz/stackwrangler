"""Interface VPC endpoint private DNS for in-VPC workloads.

Runs as its own process (root, UDP/TCP 53). Each VPC Docker network gets
this container's address; workloads start with ``--dns`` set to that
address. A query on VPC A's address only sees Interface endpoints in VPC A
with ``PrivateDnsEnabled``.

Answers A records for the regional service hostnames (sts / logs / ssm /
ecs / ecr.api / ecr.dkr) with the endpoint proxy IP. Other names are
forwarded to 8.8.8.8.
"""

from __future__ import annotations

import ipaddress
import logging
import os
import select
import socket
import struct
import threading
import time

LOG = logging.getLogger("awsbox.vpce.dns")

_A = 1
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
# vpc_id → list of {hosts: set[str], wildcards: list[str], ip: str, endpoint_id: str}
_ENDPOINTS: dict[str, list[dict]] = {}
_API_OK = False


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
            LOG.warning("docker client unavailable; VPCE private DNS disabled", exc_info=True)
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


def _access_key() -> str:
    raw = os.environ.get("ROOT_ACCESS_KEYS") or "awsbox"
    return raw.split(",")[0].strip() or "awsbox"


def _secret_key() -> str:
    return os.environ.get("VPCE_DNS_SECRET") or os.environ.get("AWSBOX_SECRET_KEY") or "awsboxawsbox"


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
        client = _docker()
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


def _handle(payload: bytes, vpc_id: str | None) -> bytes | None:
    parsed = _parse(payload)
    if parsed is None:
        if len(payload) >= 2:
            tid = struct.unpack("!H", payload[:2])[0]
            return _pack(tid, False, b"\x00" + struct.pack("!HH", _A, _IN), _FORMERR, [])
        return None
    tid, rd, qname, qtype, question = parsed
    try:
        answer = _lookup(qname, qtype, vpc_id)
    except Exception:
        LOG.warning("lookup failed for %s", qname, exc_info=True)
        return _pack(tid, rd, question, _SERVFAIL, [])
    if answer is None:
        forwarded = _forward(payload)
        if forwarded is not None:
            return forwarded
        return _pack(tid, rd, question, _SERVFAIL, [])
    rcode, rrs = answer
    if rcode == 0 and rrs:
        LOG.info("answer %s vpc=%s A", qname, vpc_id)
    elif rcode == _NXDOMAIN:
        LOG.info("nxdomain %s vpc=%s", qname, vpc_id)
    return _pack(tid, rd, question, rcode, rrs)


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
    LOG.info("VPCE private DNS TCP/53")
    while True:
        try:
            conn, _addr = sock.accept()
        except OSError:
            time.sleep(0.2)
            continue
        threading.Thread(target=_tcp_client, args=(conn,), daemon=True).start()


def _tcp_client(conn: socket.socket) -> None:
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
        response = _handle(payload, vpc_id)
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
        LOG.info("VPCE private DNS UDP/53 on %s vpc=%s", ip, _SELF_IPS.get(ip))
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
                response = _handle(payload, vpc_id)
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
    LOG.info("VPCE private DNS resolver starting")
    threading.Thread(target=_tcp_server, name="vpce-dns-tcp", daemon=True).start()
    _udp_loop()


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "serve":
        serve()
