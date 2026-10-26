"""Shared DNS plumbing for the per-VPC resolver (private zones + VPCE names).

Mounted at ``/opt/awsbox/dns/awsbox_dns_common.py``. Both
``r53_private_resolver`` and ``vpce_private_dns`` import it, so there is one
wire-format codec, one upstream forwarder and one UDP/TCP 53 server.

Each VPC's Docker network has this container's address; workloads get that
address as ``--dns``. A query arriving on VPC A's address is scoped to VPC A.
"""

from __future__ import annotations

import logging
import os
import select
import socket
import struct
import threading
import time
from collections.abc import Callable

LOG = logging.getLogger("awsbox.dns")

A = 1
NS = 2
CNAME = 5
SOA = 6
AAAA = 28
IN = 1
SERVFAIL = 2
NXDOMAIN = 3
FORMERR = 1

RR = tuple[str, int, int, bytes]

_CONNECT_LOCK = threading.Lock()
SELF_IPS: dict[str, str] = {}
_SELF_IPS_AT = 0.0
_DOCKER = None


class Answer:
    def __init__(self, rcode: int, rrs: list[RR]):
        self.rcode = rcode
        self.rrs = rrs


def norm(name: str) -> str:
    return name.strip().rstrip(".").lower()


def access_key() -> str:
    raw = os.environ.get("ROOT_ACCESS_KEYS") or "awsbox"
    return raw.split(",")[0].strip() or "awsbox"


def secret_key() -> str:
    return (
        os.environ.get("R53_RESOLVER_SECRET")
        or os.environ.get("VPCE_DNS_SECRET")
        or os.environ.get("AWSBOX_SECRET_KEY")
        or "awsboxawsbox"
    )


def boto(service: str):
    import boto3
    from botocore.config import Config

    cfg = Config(connect_timeout=2, read_timeout=8, retries={"max_attempts": 2})
    return boto3.client(
        service,
        endpoint_url="http://127.0.0.1:4566",
        region_name=os.environ.get("AWS_DEFAULT_REGION") or "us-east-1",
        aws_access_key_id=access_key(),
        aws_secret_access_key=secret_key(),
        config=cfg,
    )


def hostname() -> str:
    try:
        return open("/etc/hostname", encoding="utf-8").read().strip()
    except OSError:
        return socket.gethostname()


def docker_client():
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
            client = docker_client()
        except Exception:
            LOG.warning("docker client unavailable; private DNS disabled", exc_info=True)
            return None
        name = f"localemu-vpc-{vpc_id}"
        try:
            net = client.networks.get(name)
        except Exception:
            LOG.info("VPC network %s does not exist yet", name)
            return None
        cid = hostname()
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
                SELF_IPS[addr] = vpc_id
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


def refresh_self_ips(force: bool = False) -> None:
    global _SELF_IPS_AT
    now = time.time()
    if not force and now - _SELF_IPS_AT < 1.0 and SELF_IPS:
        return
    try:
        client = docker_client()
        cid = hostname()
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
            SELF_IPS.clear()
            SELF_IPS.update(mapping)
        _SELF_IPS_AT = now
    except Exception:
        LOG.debug("self-ip refresh failed", exc_info=True)


def write_name(name: str) -> bytes:
    out = b""
    for label in norm(name).split("."):
        if not label:
            continue
        raw = label.encode("ascii")
        out += bytes([len(raw)]) + raw
    return out + b"\x00"


def read_name(data: bytes, offset: int) -> tuple[str, int]:
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


def pack(tid: int, rd: bool, question: bytes, rcode: int, rrs: list[RR]) -> bytes:
    header = struct.pack("!HHHHHH", tid, _flags(rd, rcode), 1, len(rrs), 0, 0)
    body = question
    for name, typ, ttl, rdata in rrs:
        body += write_name(name) + struct.pack("!HHIH", typ, IN, ttl, len(rdata)) + rdata
    return header + body


def parse(data: bytes) -> tuple[int, bool, str, int, bytes] | None:
    if len(data) < 12:
        return None
    tid, flags = struct.unpack("!HH", data[:4])
    rd = bool(flags & 0x0100)
    try:
        qname, off = read_name(data, 12)
    except Exception:
        return None
    if off + 4 > len(data):
        return None
    qtype, _qclass = struct.unpack("!HH", data[off : off + 4])
    return tid, rd, qname, qtype, data[12 : off + 4]


def a_rdata(ip: str) -> bytes:
    return socket.inet_aton(ip)


def aaaa_rdata(ip: str) -> bytes:
    return socket.inet_pton(socket.AF_INET6, ip)


def _upstreams() -> list[str]:
    raw = os.environ.get("AWSBOX_DNS_UPSTREAM") or "8.8.8.8"
    return [item.strip() for item in raw.split(",") if item.strip()]


def forward(payload: bytes) -> bytes | None:
    """Send the query to the upstream resolver(s); first answer wins."""
    for server in _upstreams():
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
                sock.settimeout(2)
                sock.sendto(payload, (server, 53))
                data, _addr = sock.recvfrom(4096)
                return data
        except OSError:
            continue
    return None


Lookup = Callable[[str, int, "str | None", "str | None"], "Answer | None"]


def handle(payload: bytes, vpc_id: str | None, local_ip: str | None, lookup: Lookup) -> bytes | None:
    """Answer from ``lookup`` or forward upstream when it returns ``None``."""
    parsed = parse(payload)
    if parsed is None:
        if len(payload) >= 2:
            tid = struct.unpack("!H", payload[:2])[0]
            return pack(tid, False, b"\x00" + struct.pack("!HH", A, IN), FORMERR, [])
        return None
    tid, rd, qname, qtype, question = parsed
    try:
        answer = lookup(qname, qtype, vpc_id, local_ip)
    except Exception:
        LOG.warning("lookup failed for %s", qname, exc_info=True)
        return pack(tid, rd, question, SERVFAIL, [])
    if answer is None:
        forwarded = forward(payload)
        if forwarded is not None:
            return forwarded
        return pack(tid, rd, question, SERVFAIL, [])
    if answer.rcode == 0 and answer.rrs:
        LOG.info("answer %s type=%s vpc=%s -> %s rr", qname, qtype, vpc_id, len(answer.rrs))
    elif answer.rcode == NXDOMAIN:
        LOG.info("nxdomain %s vpc=%s", qname, vpc_id)
    return pack(tid, rd, question, answer.rcode, answer.rrs)


def _recv_exact(conn: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            break
        buf += chunk
    return buf


def _tcp_client(conn: socket.socket, lookup: Lookup) -> None:
    try:
        conn.settimeout(5)
        header = _recv_exact(conn, 2)
        if len(header) < 2:
            return
        length = struct.unpack("!H", header)[0]
        payload = _recv_exact(conn, length)
        local_ip = conn.getsockname()[0]
        refresh_self_ips()
        vpc_id = SELF_IPS.get(local_ip)
        if vpc_id is None:
            refresh_self_ips(force=True)
            vpc_id = SELF_IPS.get(local_ip)
        response = handle(payload, vpc_id, local_ip, lookup)
        if response:
            conn.sendall(struct.pack("!H", len(response)) + response)
    except OSError:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass


def _tcp_server(lookup: Lookup) -> None:
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
            conn, _addr = sock.accept()
        except OSError:
            time.sleep(0.2)
            continue
        threading.Thread(target=_tcp_client, args=(conn, lookup), daemon=True).start()


def _ensure_udp(bound: dict[str, socket.socket]) -> None:
    refresh_self_ips()
    # Loopback for dig @127.0.0.1 inside the emulator (public zones).
    want = set(SELF_IPS)
    want.add("127.0.0.1")
    for ip in list(want):
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
        LOG.info("private DNS UDP/53 on %s vpc=%s", ip, SELF_IPS.get(ip) or "-")
    for ip in list(bound):
        if ip not in want:
            try:
                bound.pop(ip).close()
            except OSError:
                pass


def _udp_loop(lookup: Lookup) -> None:
    bound: dict[str, socket.socket] = {}
    while True:
        _ensure_udp(bound)
        if not bound:
            time.sleep(0.4)
            continue
        try:
            ready, _, _ = select.select(list(bound.values()), [], [], 0.4)
        except (OSError, ValueError):
            time.sleep(0.2)
            continue
        for sock in ready:
            try:
                payload, addr = sock.recvfrom(4096)
            except OSError:
                continue
            local_ip = sock.getsockname()[0]
            try:
                response = handle(payload, SELF_IPS.get(local_ip), local_ip, lookup)
            except Exception:
                LOG.warning("udp query failed", exc_info=True)
                continue
            if not response:
                continue
            try:
                sock.sendto(response, addr)
            except OSError:
                LOG.debug("udp send failed", exc_info=True)


def serve(lookup: Lookup, label: str) -> None:
    import signal

    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    os.environ["AWS_EC2_METADATA_DISABLED"] = "true"
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    LOG.info("%s starting", label)
    threading.Thread(target=_tcp_server, args=(lookup,), name="awsbox-dns-tcp", daemon=True).start()
    _udp_loop(lookup)
