"""HTTP/HTTPS reverse proxy and TCP/TLS forwarder for ELBv2 listeners.

HTTP listeners honour host and path rules. TCP listeners bind the
requested port and, when host iptables is available, DNAT in the host
netns so instance targets see the client source address. TLS/HTTPS
listeners terminate with the ACM certificate attached to the listener
when present, otherwise LocalEmu's default self-signed certificate.

Scope:
- HTTP listeners: plain HTTP reverse proxy.
- HTTPS listeners: real TLS termination using the listener ACM
  certificate (or LocalEmu default); decrypted request is forwarded as
  HTTP to the target with ``X-Forwarded-Proto: https``.
- Round-robin across healthy targets (falls back to all registered if none
  are healthy yet, so initial requests don't 503 while health checks warm up).
- Stickiness and WebSocket upgrade handling are not implemented.
"""

from __future__ import annotations

import http.client
import http.server
import logging
import os
import socket
import ssl
import tempfile
import threading
import time
from dataclasses import dataclass, field
from itertools import count
from typing import Optional

from localemu.services.elbv2.stickiness import (
    AWSALB_COOKIE,
    StickyStore,
    build_set_cookie,
    fresh_cookie_id,
    parse_awsalb_cookie,
    read_stickiness_config,
)

LOG = logging.getLogger(__name__)

_HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailers",
    "transfer-encoding",
    "upgrade",
    "content-length",
}


def _is_websocket_upgrade(headers) -> bool:
    """RFC 6455: a WebSocket handshake has ``Upgrade: websocket`` and
    ``Connection: Upgrade`` (case-insensitive, Connection may be a
    comma-separated list)."""
    upgrade = (headers.get("Upgrade") or "").strip().lower()
    if upgrade != "websocket":
        return False
    connection = (headers.get("Connection") or "").lower()
    return "upgrade" in [t.strip() for t in connection.split(",")]


def _pipe_sockets(a, b) -> None:
    """Bidirectional byte pump between two sockets until either closes.

    Used for WebSocket frame tunneling: once both ends have agreed on
    101 Switching Protocols, the LB is just a TCP relay. Spawns one
    daemon thread per direction; the call blocks on the join so the
    BaseHTTPRequestHandler keeps the connection open for the duration.
    """
    def _copy(src, dst):
        try:
            src.settimeout(None)
            while True:
                chunk = src.recv(65536)
                if not chunk:
                    break
                dst.sendall(chunk)
        except Exception:
            pass
        finally:
            try:
                dst.shutdown(socket.SHUT_WR)
            except Exception:
                pass

    t1 = threading.Thread(target=_copy, args=(a, b), daemon=True)
    t2 = threading.Thread(target=_copy, args=(b, a), daemon=True)
    t1.start(); t2.start()
    t1.join(); t2.join()


@dataclass
class Target:
    target_id: str  # instance-id or IP, OR a Lambda function ARN
    port: int
    host: str  # resolved host/IP to connect to (empty for Lambda targets)
    health: str = "initial"  # initial | healthy | unhealthy
    lambda_arn: Optional[str] = None  # set when this target is a Lambda function


@dataclass
class TargetGroup:
    arn: str
    name: str
    protocol: str = "HTTP"
    port: int = 80
    health_check_port: Optional[int] = None
    targets: dict[str, Target] = field(default_factory=dict)
    sticky_store: StickyStore = field(default_factory=StickyStore)
    _rr_counter: "count" = field(default_factory=lambda: count(0))
    _lock: threading.Lock = field(default_factory=threading.Lock)

    def pick_target(self) -> Optional[Target]:
        with self._lock:
            all_targets = list(self.targets.values())
        if not all_targets:
            return None
        healthy = [t for t in all_targets if t.health == "healthy"]
        # Unhealthy targets take no new connections. ``initial`` is only
        # the warmup window before the first probe.
        pool = healthy or [t for t in all_targets if t.health == "initial"]
        if not pool:
            return None
        idx = next(self._rr_counter) % len(pool)
        return pool[idx]

    def target_by_key(self, key: str) -> Optional[Target]:
        """O(1) lookup used by the sticky-cookie path. Returns None
        if the target has been deregistered since the cookie was
        issued — the proxy then re-picks via round-robin."""
        with self._lock:
            return self.targets.get(key)

    def target_key(self, target: Target) -> str:
        """The same composite key used in ``targets`` (Id:Port)."""
        return f"{target.target_id}:{target.port}"


@dataclass
class Listener:
    arn: str
    lb_arn: str
    protocol: str
    port: int
    target_group_arn: str
    server: Optional[http.server.ThreadingHTTPServer] = None
    thread: Optional[threading.Thread] = None
    ssl_ctx: Optional[ssl.SSLContext] = None


@dataclass
class L4Listener:
    """TCP or TLS listener. TLS is terminated here; TCP may be DNAT'd."""

    arn: str
    lb_arn: str
    protocol: str
    port: int
    target_group_arn: str
    scheme: str
    dest_ips: list[str] = field(default_factory=list)
    server_sock: Optional[socket.socket] = None
    thread: Optional[threading.Thread] = None
    ssl_ctx: Optional[ssl.SSLContext] = None
    dnat: bool = False


@dataclass
class Rule:
    """An ELBv2 listener rule.

    Mirrors the subset of the ELBv2 ``Rule`` shape that the proxy is
    actually able to act on. ``conditions`` is the raw list of dicts
    boto/moto returns (``Field`` + one of HostHeaderConfig /
    PathPatternConfig / HttpHeaderConfig / QueryStringConfig /
    SourceIpConfig). ``actions`` is the raw DefaultActions-shaped list
    (Type + per-type config block).

    Priority comparison matches the ELBv2 contract: ``"default"`` is
    always evaluated LAST; everything else sorts as a positive integer
    ascending (lower number = higher precedence).
    """

    arn: str
    listener_arn: str
    priority: str  # "default" or stringified positive int
    conditions: list[dict] = field(default_factory=list)
    actions: list[dict] = field(default_factory=list)

    @property
    def priority_key(self) -> int:
        if self.priority == "default":
            return 10_000_000  # last
        try:
            return int(self.priority)
        except ValueError:
            return 10_000_000


def _path_pattern_match(pattern: str, path: str) -> bool:
    """ALB path-pattern matching.

    Supports ``*`` (zero or more characters, including slashes) and ``?``
    (exactly one character) wildcards — that is the documented ALB
    semantics, NOT shell-glob's ``*`` (which doesn't cross ``/``). The
    request path is matched without its query string.
    """
    import re

    path_only = path.split("?", 1)[0]
    regex = "^" + re.escape(pattern).replace(r"\*", ".*").replace(r"\?", ".") + "$"
    return re.match(regex, path_only) is not None


def _host_header_match(pattern: str, host: str) -> bool:
    """ALB host-header matching. Same wildcard semantics as path-patterns,
    plus the standard ``*.example.com`` use case. Host is compared
    case-insensitively per RFC 3986."""
    import re

    host = host.split(":", 1)[0].lower()
    pat = pattern.lower()
    regex = "^" + re.escape(pat).replace(r"\*", "[^.]*").replace(r"\?", ".") + "$"
    if re.match(regex, host) is not None:
        return True
    # Also accept the broader ``*`` wildcard semantics (matches dots too),
    # because real ALBs do — the documented behaviour differs between
    # host header (no-dot) and path pattern (any-char), but in practice
    # ALB hosts also accept dot-spanning ``*`` for many configurations.
    broad = "^" + re.escape(pat).replace(r"\*", ".*").replace(r"\?", ".") + "$"
    return re.match(broad, host) is not None


def _condition_matches(cond: dict, *, host: str, path: str, headers, source_ip: str) -> bool:
    """Evaluate a single ELBv2 RuleCondition dict against the request."""
    field = (cond.get("Field") or "").lower()
    if field == "host-header":
        values = (cond.get("HostHeaderConfig") or {}).get("Values") or cond.get("Values") or []
        return any(_host_header_match(v, host) for v in values)
    if field == "path-pattern":
        values = (cond.get("PathPatternConfig") or {}).get("Values") or cond.get("Values") or []
        return any(_path_pattern_match(v, path) for v in values)
    if field == "http-header":
        cfg = cond.get("HttpHeaderConfig") or {}
        name = cfg.get("HttpHeaderName") or ""
        values = cfg.get("Values") or []
        actual = headers.get(name, "")
        return any(_path_pattern_match(v, actual) for v in values)
    if field == "source-ip":
        import ipaddress

        values = (cond.get("SourceIpConfig") or {}).get("Values") or []
        try:
            ip = ipaddress.ip_address(source_ip)
        except ValueError:
            return False
        for cidr in values:
            try:
                if ip in ipaddress.ip_network(cidr, strict=False):
                    return True
            except ValueError:
                continue
        return False
    if field == "query-string":
        cfg = cond.get("QueryStringConfig") or {}
        kvs = cfg.get("Values") or []
        from urllib.parse import parse_qsl

        qs = path.split("?", 1)[1] if "?" in path else ""
        params = parse_qsl(qs, keep_blank_values=True)
        for kv in kvs:
            key = kv.get("Key")
            val = kv.get("Value")
            for pk, pv in params:
                if key is not None and not _path_pattern_match(key, pk):
                    continue
                if val is not None and not _path_pattern_match(val, pv):
                    continue
                return True
        return False
    # Unknown / unhandled fields default to "doesn't match" so the rule
    # is conservative — falling through to the listener's default action
    # is the AWS-compatible behaviour.
    return False


class _ProxyHandler(http.server.BaseHTTPRequestHandler):
    # Injected by server subclass
    _router: "ListenerRouter" = None  # type: ignore[assignment]
    _listener_arn: str = ""

    # Silence the default stderr logging
    def log_message(self, format: str, *args) -> None:  # noqa: A002
        LOG.debug("elbv2-listener %s - " + format, self._listener_arn, *args)

    def _select_target_group_arn(self, listener: Listener) -> tuple[str, Optional[dict]]:
        """Walk rules in priority order; return the chosen target-group
        ARN plus the matched action dict (or None for the default-path
        fallback). Non-forward actions short-circuit by returning their
        action dict with an empty TG ARN — the caller renders the
        response directly without proxying."""
        host = self.headers.get("Host", "")
        rules = self._router.rules.get(self._listener_arn) or []
        for rule in sorted(rules, key=lambda r: r.priority_key):
            # An empty conditions list with priority "default" matches everything;
            # any other rule with no conditions cannot match (real ALB rejects it).
            if not rule.conditions and rule.priority != "default":
                continue
            all_match = all(
                _condition_matches(
                    c,
                    host=host,
                    path=self.path,
                    headers=self.headers,
                    source_ip=self.client_address[0],
                )
                for c in rule.conditions
            ) if rule.conditions else True
            if not all_match:
                continue
            for action in rule.actions:
                a_type = (action.get("Type") or "").lower()
                if a_type == "forward":
                    tg_arn = action.get("TargetGroupArn") or ""
                    if not tg_arn:
                        fw = action.get("ForwardConfig") or {}
                        tgs = fw.get("TargetGroups") or []
                        if tgs:
                            tg_arn = tgs[0].get("TargetGroupArn", "")
                    if tg_arn:
                        return tg_arn, None
                elif a_type in {"fixed-response", "redirect"}:
                    return "", action
            # If the matched rule had no actionable action (e.g. authenticate-*
            # is unsupported), fall through to the next rule.
        return listener.target_group_arn, None

    def _render_action(self, action: dict, listener: Listener) -> None:
        a_type = (action.get("Type") or "").lower()
        if a_type == "fixed-response":
            cfg = action.get("FixedResponseConfig") or {}
            status = int(cfg.get("StatusCode") or 200)
            body = (cfg.get("MessageBody") or "").encode("utf-8")
            content_type = cfg.get("ContentType") or "text/plain"
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)
            return
        if a_type == "redirect":
            cfg = action.get("RedirectConfig") or {}
            status = 301 if cfg.get("StatusCode") == "HTTP_301" else 302
            scheme = (cfg.get("Protocol") or "#{protocol}").replace(
                "#{protocol}", listener.protocol.lower()
            ).lower()
            host = (cfg.get("Host") or "#{host}").replace(
                "#{host}", self.headers.get("Host", "").split(":", 1)[0]
            )
            port = (cfg.get("Port") or "#{port}").replace(
                "#{port}", str(listener.port)
            )
            req_path = self.path.split("?", 1)[0]
            req_query = self.path.split("?", 1)[1] if "?" in self.path else ""
            path = (cfg.get("Path") or "#{path}").replace("#{path}", req_path)
            query = (cfg.get("Query") or "#{query}").replace("#{query}", req_query)
            url = f"{scheme}://{host}:{port}{path}"
            if query:
                url += "?" + query
            self.send_response(status)
            self.send_header("Location", url)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        # Anything else (authenticate-cognito, etc) just falls through to 503.
        self.send_error(503, f"Unsupported action type {a_type}")

    def _handle(self) -> None:
        listener = self._router.listeners.get(self._listener_arn)
        if not listener:
            self.send_error(503, "Listener not available")
            return

        chosen_tg_arn, terminal_action = self._select_target_group_arn(listener)
        if terminal_action is not None:
            self._render_action(terminal_action, listener)
            return

        tg = self._router.target_groups.get(chosen_tg_arn)
        if not tg:
            self.send_error(503, "No target group")
            return

        # Sticky-target resolution: when stickiness is enabled and the
        # request carries a valid AWSALB cookie mapping to a live
        # target, route there. Otherwise pick fresh and remember the
        # mapping so the response can emit Set-Cookie.
        sticky_cfg = read_stickiness_config(chosen_tg_arn)
        sticky_active = (
            sticky_cfg.enabled and sticky_cfg.type == "lb_cookie"
        )
        sticky_cookie_to_emit: Optional[str] = None
        target: Optional[Target] = None
        if sticky_active:
            existing_cookie = parse_awsalb_cookie(
                self.headers.get("Cookie", ""),
            )
            if existing_cookie:
                pin = tg.sticky_store.lookup(existing_cookie)
                if pin is not None:
                    target = tg.target_by_key(pin.target_key)
                    if target is None:
                        # Target was deregistered — drop the stale pin
                        # and fall through to fresh selection. Per AWS:
                        # a new cookie gets minted in this case.
                        tg.sticky_store.forget(existing_cookie)
        if target is None:
            target = tg.pick_target()
            if target is not None and sticky_active:
                sticky_cookie_to_emit = fresh_cookie_id()
                tg.sticky_store.remember(
                    sticky_cookie_to_emit,
                    tg.target_key(target),
                    sticky_cfg.cookie_duration,
                )
        if not target:
            self.send_error(503, "No registered targets")
            return

        try:
            body_len = int(self.headers.get("Content-Length", "0") or 0)
        except ValueError:
            body_len = 0
        body = self.rfile.read(body_len) if body_len > 0 else None

        # WebSocket Upgrade tunneling. ALB supports the HTTP/1.1
        # Upgrade contract — the LB MUST forward the Upgrade headers
        # verbatim, expect a 101 Switching Protocols back from the
        # target, and then pipe bytes bidirectionally for the
        # lifetime of the connection. No re-balancing mid-stream;
        # the connection is pinned to the picked target.
        if _is_websocket_upgrade(self.headers):
            return self._handle_websocket(target, listener, body)

        # Lambda target group: invoke the function directly via boto3 with
        # the AWS-documented ALB→Lambda event shape, then translate the
        # function's response (statusCode/headers/body/isBase64Encoded)
        # back to an HTTP response. The HTTPConnection-based proxy path
        # cannot reach a function ARN.
        if target.lambda_arn:
            return self._handle_lambda_target(
                target, chosen_tg_arn, listener, body,
            )

        try:
            conn = http.client.HTTPConnection(target.host, target.port, timeout=30)
            headers = {
                k: v for k, v in self.headers.items() if k.lower() not in _HOP_BY_HOP
            }
            headers["X-Forwarded-For"] = self.client_address[0]
            headers["X-Forwarded-Proto"] = listener.protocol.lower()
            headers["X-Forwarded-Port"] = str(listener.port)
            conn.request(self.command, self.path, body=body, headers=headers)
            upstream = conn.getresponse()
            self.send_response(upstream.status, upstream.reason)
            for k, v in upstream.getheaders():
                if k.lower() in _HOP_BY_HOP:
                    continue
                self.send_header(k, v)
            if sticky_cookie_to_emit is not None:
                self.send_header(
                    "Set-Cookie",
                    build_set_cookie(
                        sticky_cookie_to_emit,
                        sticky_cfg.cookie_duration,
                        secure=listener.protocol.upper() == "HTTPS",
                    ),
                )
            data = upstream.read()
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if data:
                self.wfile.write(data)
            conn.close()
        except Exception as e:
            LOG.debug("Upstream proxy error to %s:%s - %s", target.host, target.port, e)
            try:
                self.send_error(502, f"Bad Gateway: {e}")
            except Exception:
                pass

    def _handle_websocket(
        self, target: "Target", listener: "Listener",
        body: Optional[bytes],
    ) -> None:
        """Proxy an HTTP/1.1 WebSocket Upgrade.

        Opens a raw TCP socket to the picked target, replays the
        request line + headers verbatim (including ``Upgrade``,
        ``Connection``, ``Sec-WebSocket-*``), forwards any pre-buffered
        body bytes, reads the response status + headers, and — if the
        target returns ``101 Switching Protocols`` — splices both
        sockets bidirectionally until either end closes.

        Backend protocol is plain TCP (no TLS); the AWS contract is
        that ALB terminates client TLS and the target receives
        plain HTTP/WS. Same shape as the existing reverse proxy.
        """
        upstream = None
        try:
            upstream = socket.create_connection(
                (target.host, target.port), timeout=30,
            )
            # Build the upstream request: keep all original headers
            # (Upgrade / Connection / Sec-WebSocket-Key /
            # Sec-WebSocket-Version / Sec-WebSocket-Protocol) verbatim
            # — those are the handshake. Strip only Host (we set our
            # own) and Content-Length (no body on the GET).
            request_lines = [
                f"{self.command} {self.path} HTTP/1.1",
                f"Host: {target.host}:{target.port}",
                f"X-Forwarded-For: {self.client_address[0]}",
                f"X-Forwarded-Proto: {listener.protocol.lower()}",
                f"X-Forwarded-Port: {listener.port}",
            ]
            for k, v in self.headers.items():
                lk = k.lower()
                if lk in ("host", "content-length"):
                    continue
                if lk in ("x-forwarded-for", "x-forwarded-proto", "x-forwarded-port"):
                    continue
                request_lines.append(f"{k}: {v}")
            wire = ("\r\n".join(request_lines) + "\r\n\r\n").encode("latin-1")
            upstream.sendall(wire)
            if body:
                upstream.sendall(body)

            # Read the response head until \r\n\r\n. The body of a 101
            # is empty by definition; for non-101 we copy what we read
            # plus drain the rest into the client.
            header_buf = b""
            while b"\r\n\r\n" not in header_buf:
                chunk = upstream.recv(4096)
                if not chunk:
                    break
                header_buf += chunk
                if len(header_buf) > 65536:
                    break

            # Splice the head straight to the client; the BaseHTTPRequest
            # Handler hasn't called send_response yet so we own the
            # wire from here.
            self.wfile.write(header_buf)
            self.wfile.flush()

            status_line = header_buf.split(b"\r\n", 1)[0]
            is_101 = b" 101 " in status_line or status_line.endswith(b" 101")
            if not is_101:
                # Backend declined the upgrade; the response head is
                # already on the wire. We do not propagate the
                # remaining body here because a non-101 response
                # makes the connection un-WebSocket; closing the
                # client side cleanly is the AWS-parity behavior.
                return

            # Splice phase. Two pipes — client→upstream and
            # upstream→client — joined until either side closes.
            _pipe_sockets(self.connection, upstream)
        except Exception as e:
            LOG.debug(
                "elbv2-listener websocket proxy error to %s:%s - %s",
                target.host, target.port, e,
            )
            try:
                self.send_error(502, f"Bad Gateway (websocket): {e}")
            except Exception:
                pass
        finally:
            try:
                if upstream is not None:
                    upstream.close()
            except Exception:
                pass

    def _handle_lambda_target(
        self, target: "Target", tg_arn: str, listener: "Listener",
        body: Optional[bytes],
    ) -> None:
        """ALB → Lambda forward.

        Builds the AWS-documented ELB Lambda event payload and invokes
        the function via the internal boto3 client. Parses ``statusCode``
        / ``headers`` / ``body`` / ``isBase64Encoded`` from the Lambda
        response and writes them back as the HTTP response.
        """
        import base64 as _b64
        import json as _json
        from urllib.parse import urlsplit, parse_qs

        try:
            from localemu.aws.connect import connect_to
            from localemu.constants import INTERNAL_AWS_SECRET_ACCESS_KEY
        except Exception:
            self.send_error(502, "Bad Gateway: cannot reach LocalEmu Lambda client")
            return

        # Build the ELB-shaped Lambda event.
        split = urlsplit(self.path)
        path = split.path or "/"
        qs_raw = parse_qs(split.query, keep_blank_values=True)
        qs_single = {k: v[0] for k, v in qs_raw.items()}
        # Headers: lowercased single-string values (ALB→Lambda contract).
        hdr_single = {k.lower(): v for k, v in self.headers.items()}
        # Detect binary body so we can base64-flag it. Heuristic: not-text.
        is_b64 = False
        body_field = ""
        if body is not None:
            try:
                body_field = body.decode("utf-8")
            except Exception:
                body_field = _b64.b64encode(body).decode("ascii")
                is_b64 = True
        event = {
            "requestContext": {"elb": {"targetGroupArn": tg_arn}},
            "httpMethod": self.command,
            "path": path,
            "queryStringParameters": qs_single,
            "headers": hdr_single,
            "body": body_field,
            "isBase64Encoded": is_b64,
        }

        # Extract account/region from the ARN: arn:aws:lambda:<region>:<account>:function:<name>
        try:
            _, _, _, region, account_id, _, fn_name = target.lambda_arn.split(":", 6)
        except Exception:
            self.send_error(502, f"Bad Gateway: malformed Lambda ARN {target.lambda_arn!r}")
            return

        try:
            clients = connect_to(
                aws_access_key_id=account_id,
                aws_secret_access_key=INTERNAL_AWS_SECRET_ACCESS_KEY,
                region_name=region,
            )
            resp = clients.lambda_.invoke(
                FunctionName=target.lambda_arn,
                InvocationType="RequestResponse",
                Payload=_json.dumps(event).encode("utf-8"),
            )
            raw = resp["Payload"].read()
        except Exception as e:
            LOG.debug("ALB→Lambda invoke failed for %s: %s", target.lambda_arn, e)
            try:
                self.send_error(502, f"Bad Gateway: Lambda invoke failed: {e}")
            except Exception:
                pass
            return

        try:
            payload = _json.loads(raw or b"{}")
        except Exception:
            self.send_error(502, "Bad Gateway: Lambda returned non-JSON payload")
            return

        status = int(payload.get("statusCode") or 200)
        headers = payload.get("headers") or {}
        out_body = payload.get("body") or ""
        if payload.get("isBase64Encoded"):
            try:
                out_bytes = _b64.b64decode(out_body)
            except Exception:
                out_bytes = b""
        else:
            out_bytes = (
                out_body.encode("utf-8") if isinstance(out_body, str)
                else bytes(out_body) if out_body else b""
            )

        self.send_response(status)
        for k, v in headers.items():
            if k.lower() in _HOP_BY_HOP:
                continue
            self.send_header(str(k), str(v))
        self.send_header("Content-Length", str(len(out_bytes)))
        self.end_headers()
        if out_bytes:
            self.wfile.write(out_bytes)

    def do_GET(self): self._handle()
    def do_POST(self): self._handle()
    def do_PUT(self): self._handle()
    def do_DELETE(self): self._handle()
    def do_PATCH(self): self._handle()
    def do_HEAD(self): self._handle()
    def do_OPTIONS(self): self._handle()


def _localemu_cert_path() -> str:
    """Path to LocalEmu's self-signed cert PEM (key + cert in one file).

    Lazy-imports the SSL helper so listener_router stays importable in
    environments where the cert dir hasn't been initialised yet (e.g. the
    unit-test fast path); :func:`install_predefined_cert_if_available`
    generates the file on demand.
    """
    from localemu.utils.ssl import (
        get_cert_pem_file_path,
        install_predefined_cert_if_available,
    )

    install_predefined_cert_if_available()
    return get_cert_pem_file_path()


# ARN -> combined PEM path (mkstemp, mode 0o600). Reused across listeners.
_acm_pem_cache: dict[str, str] = {}


def _acm_cert_pem_path(certificate_arn: str) -> Optional[str]:
    """Write the ACM keypair to a combined PEM and return its path.

    Looks the ARN up in moto's ACM backend (same process as LocalEmu).
    Returns ``None`` when the ARN is missing or the keypair cannot be
    loaded so callers can fall back to the LocalEmu default cert.
    """
    if not certificate_arn:
        return None
    cached = _acm_pem_cache.get(certificate_arn)
    if cached and os.path.isfile(cached):
        return cached
    parts = certificate_arn.split(":")
    if len(parts) < 6 or parts[2] != "acm":
        return None
    region = parts[3]
    account_id = parts[4]
    try:
        import moto.backends as moto_backends

        acm = moto_backends.get_backend("acm")[account_id][region]
        bundle = acm.get_certificate(certificate_arn)
        key = bundle.key if isinstance(bundle.key, bytes) else bundle.key.encode()
        cert = bundle.cert if isinstance(bundle.cert, bytes) else bundle.cert.encode()
    except Exception as exc:
        LOG.warning("ACM certificate %s not loadable: %s", certificate_arn, exc)
        return None

    payload = key.rstrip(b"\n") + b"\n" + cert
    if not cert.endswith(b"\n"):
        payload += b"\n"
    fd = -1
    path = ""
    try:
        fd, path = tempfile.mkstemp(prefix="localemu-elbv2-acm-", suffix=".pem")
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as fh:
            fd = -1  # owned by fh
            fh.write(payload)
    except OSError as exc:
        if fd >= 0:
            try:
                os.close(fd)
            except OSError:
                pass
        if path:
            try:
                os.unlink(path)
            except OSError:
                pass
        LOG.warning("Could not write ACM PEM for %s: %s", certificate_arn, exc)
        return None
    _acm_pem_cache[certificate_arn] = path
    return path


def _tls_cert_path(certificate_arn: Optional[str] = None) -> str:
    """Prefer the listener ACM keypair; otherwise LocalEmu's default cert."""
    if certificate_arn:
        acm_path = _acm_cert_pem_path(certificate_arn)
        if acm_path:
            return acm_path
    return _localemu_cert_path()


def _build_server_ssl_context(certificate_arn: Optional[str] = None) -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=_tls_cert_path(certificate_arn))
    return ctx


def _allocate_port() -> int:
    """Allocate an ephemeral TCP port by binding to :0 and releasing."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("0.0.0.0", 0))  # noqa: S104
        return s.getsockname()[1]


def _tcp_ping(host: str, port: int, timeout: float = 2.0) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


class ListenerRouter:
    """Singleton registry for ELBv2 load balancers, listeners, and target groups."""

    def __init__(self) -> None:
        self.load_balancers: dict[str, dict] = {}  # arn -> metadata
        self.listeners: dict[str, Listener] = {}
        self.target_groups: dict[str, TargetGroup] = {}
        # listener_arn -> list[Rule], evaluated in priority order on each request
        self.rules: dict[str, list[Rule]] = {}
        # rule_arn -> Rule (for O(1) modify/delete)
        self._rules_by_arn: dict[str, Rule] = {}
        self.l4_listeners: dict[str, "L4Listener"] = {}
        self._lock = threading.RLock()
        self._dnat_lock = threading.Lock()
        self._dnat_sig: tuple[tuple[str, ...], ...] = ()
        self._health_thread: Optional[threading.Thread] = None
        self._stop = threading.Event()

    # ------------ Load balancers ------------
    def register_lb(
        self, arn: str, name: str, dns_name: str, scheme: str, lb_type: str,
        vpc_networks: Optional[list[str]] = None,
    ) -> None:
        with self._lock:
            self.load_balancers[arn] = {
                "arn": arn, "name": name, "dns_name": dns_name,
                "scheme": scheme, "type": lb_type,
                "vpc_networks": list(vpc_networks or []),
            }
        self._publish_dns()

    def forget_lb(self, arn: str) -> None:
        with self._lock:
            self.load_balancers.pop(arn, None)
            still: set[str] = set()
            for lb in self.load_balancers.values():
                still.update(str(n) for n in (lb.get("vpc_networks") or []))
        self._publish_dns()
        _leave_unused_networks(still)

    def listener_arns_for(self, lb_arn: str) -> list[str]:
        with self._lock:
            found = [arn for arn, listener in self.listeners.items() if listener.lb_arn == lb_arn]
            found.extend(arn for arn, l4 in self.l4_listeners.items() if l4.lb_arn == lb_arn)
        return found

    # ------------ Target groups ------------
    def register_target_group(self, tg: TargetGroup) -> None:
        with self._lock:
            self.target_groups[tg.arn] = tg
            self._ensure_health_thread()

    def add_targets(self, tg_arn: str, targets: list[dict]) -> None:
        tg = self.target_groups.get(tg_arn)
        if not tg:
            return
        with tg._lock:
            for t in targets:
                tid = t.get("Id") or ""
                port = int(t.get("Port") or tg.port)
                # Lambda targets are AWS function ARNs — they are NOT routable
                # hostnames; trying to ``HTTPConnection(arn, port)`` raises
                # ``'idna' codec can't encode characters in position 0-63:
                # label too long``. Detect them here and let the forward
                # path branch on ``Target.lambda_arn``.
                if tid.startswith("arn:aws:lambda:") or tid.startswith("arn:aws-us-gov:lambda:") or tid.startswith("arn:aws-cn:lambda:"):
                    tg.targets[f"{tid}:{port}"] = Target(
                        target_id=tid, port=port, host="", lambda_arn=tid,
                    )
                    continue
                host = tid if _looks_like_host(tid) else ""
                if tid.startswith("i-"):
                    resolved, net = _instance_endpoint(tid)
                    if resolved:
                        host = resolved
                    if net:
                        _join_network(net)
                key = f"{tid}:{port}"
                tg.targets[key] = Target(target_id=tid, port=port, host=host)
        self._refresh_dnat()

    def remove_targets(self, tg_arn: str, targets: list[dict]) -> None:
        tg = self.target_groups.get(tg_arn)
        if not tg:
            return
        with tg._lock:
            for t in targets:
                tid = t.get("Id") or ""
                port = int(t.get("Port") or tg.port)
                tg.targets.pop(f"{tid}:{port}", None)
        self._refresh_dnat()

    def describe_target_health(self, tg_arn: str) -> list[dict]:
        tg = self.target_groups.get(tg_arn)
        if not tg:
            return []
        out = []
        with tg._lock:
            targets = list(tg.targets.values())
        for t in targets:
            _resolve_target(t)
            port = tg.health_check_port or t.port
            if t.host:
                ok = _tcp_ping(t.host, port)
                t.health = "healthy" if ok else "unhealthy"
            elif t.target_id.startswith("i-") and not t.lambda_arn:
                t.health = "initial"
            else:
                t.health = "unhealthy"
            state = t.health
            if state == "healthy":
                reason = "Target.HealthyThresholdCount"
            elif state == "initial":
                reason = "Elb.RegistrationInProgress"
            else:
                reason = "Target.FailedHealthChecks"
            out.append({
                "Target": {"Id": t.target_id, "Port": t.port},
                "HealthCheckPort": str(port),
                "TargetHealth": {
                    "State": state,
                    "Reason": reason,
                    "Description": f"Target is {state}",
                },
            })
        self._refresh_dnat()
        return out

    # ------------ Listeners ------------
    def start_listener(
        self, lb_arn: str, listener_arn: str, protocol: str, requested_port: int,
        target_group_arn: str,
        scheme: str = "internet-facing",
        vpc_networks: Optional[list[str]] = None,
        certificate_arn: Optional[str] = None,
    ) -> int:
        """Start a listener on the requested port and return that port.

        HTTPS listeners terminate TLS with the ACM certificate attached
        to the listener when present, otherwise LocalEmu's default
        self-signed PEM (``utils/ssl.get_cert_pem_file_path()``). Without
        this wrap, a TLS ClientHello on the listener port is interpreted
        as plain HTTP and the server replies with a 400 that the TLS
        client can't parse.
        """
        proto = (protocol or "").upper()
        if proto in {"TCP", "TLS"}:
            return self._start_l4(
                lb_arn, listener_arn, proto, requested_port, target_group_arn,
                scheme, list(vpc_networks or []), certificate_arn,
            )

        port = int(requested_port or 80)
        bind_host = _bind_host(scheme, list(vpc_networks or []))

        class _Server(http.server.ThreadingHTTPServer):
            daemon_threads = True
            # Mutable so ModifyListener / AddListenerCertificates can reload
            # without rebinding the listening socket (#594).
            _ssl_ctx: Optional[ssl.SSLContext] = None

            def get_request(self):
                conn, addr = self.socket.accept()
                ctx = self._ssl_ctx
                if ctx is not None:
                    conn = ctx.wrap_socket(conn, server_side=True)
                return conn, addr

        listener = Listener(
            arn=listener_arn, lb_arn=lb_arn, protocol=protocol,
            port=requested_port, target_group_arn=target_group_arn,
        )

        handler_cls = type(
            f"ProxyHandler_{listener_arn[-8:]}",
            (_ProxyHandler,),
            {"_router": self, "_listener_arn": listener_arn},
        )

        try:
            server = _Server((bind_host, port), handler_cls)  # noqa: S104
        except OSError as e:
            LOG.warning("Could not bind listener %s on port %s: %s", listener_arn, port, e)
            return 0

        if (protocol or "").upper() in {"HTTPS", "TLS"}:
            try:
                ssl_ctx = _build_server_ssl_context(certificate_arn)
                server._ssl_ctx = ssl_ctx
                listener.ssl_ctx = ssl_ctx
            except Exception as e:
                LOG.warning(
                    "Could not enable TLS on listener %s (%s); falling back to plain HTTP",
                    listener_arn, e,
                )

        thread = threading.Thread(
            target=server.serve_forever, name=f"elbv2-listener-{listener_arn[-8:]}",
            daemon=True,
        )
        thread.start()
        listener.server = server
        listener.thread = thread
        with self._lock:
            self.listeners[listener_arn] = listener
        LOG.info(
            "ELBv2 listener %s bound to %s:%s (%s/%s)",
            listener_arn, bind_host, port, protocol, requested_port,
        )
        self._publish_dns()
        return port

    def reload_listener_certificate(
        self, listener_arn: str, certificate_arn: Optional[str] = None,
    ) -> bool:
        """Rebuild live TLS material for a running HTTPS/TLS listener (#594)."""
        try:
            ctx = _build_server_ssl_context(certificate_arn)
        except Exception as exc:
            LOG.warning(
                "ELBv2 could not reload certificate for %s: %s", listener_arn, exc,
            )
            return False
        with self._lock:
            l4 = self.l4_listeners.get(listener_arn)
            listener = self.listeners.get(listener_arn)
        if l4 is not None and (l4.protocol or "").upper() == "TLS":
            l4.ssl_ctx = ctx
            LOG.info(
                "ELBv2 TLS listener %s reloaded certificate %s",
                listener_arn, certificate_arn or "(default)",
            )
            return True
        if listener is not None and listener.server is not None:
            listener.ssl_ctx = ctx
            setattr(listener.server, "_ssl_ctx", ctx)
            LOG.info(
                "ELBv2 HTTPS listener %s reloaded certificate %s",
                listener_arn, certificate_arn or "(default)",
            )
            return True
        LOG.debug("ELBv2 reload skipped; no live listener for %s", listener_arn)
        return False

    # ------------ Listener rules ------------
    def register_rule(
        self,
        *,
        rule_arn: str,
        listener_arn: str,
        priority: str,
        conditions: list[dict],
        actions: list[dict],
    ) -> None:
        rule = Rule(
            arn=rule_arn,
            listener_arn=listener_arn,
            priority=str(priority),
            conditions=list(conditions or []),
            actions=list(actions or []),
        )
        with self._lock:
            # Drop any prior version of this rule first so modify-flows work.
            self._rules_by_arn[rule_arn] = rule
            existing = [r for r in self.rules.get(listener_arn, []) if r.arn != rule_arn]
            existing.append(rule)
            self.rules[listener_arn] = existing

    def remove_rule(self, rule_arn: str) -> None:
        with self._lock:
            rule = self._rules_by_arn.pop(rule_arn, None)
            if not rule:
                return
            remaining = [
                r for r in self.rules.get(rule.listener_arn, []) if r.arn != rule_arn
            ]
            if remaining:
                self.rules[rule.listener_arn] = remaining
            else:
                self.rules.pop(rule.listener_arn, None)

    def set_rule_priorities(self, mapping: dict[str, str]) -> None:
        """Update rule priorities in-place. ``mapping`` is rule_arn -> priority."""
        with self._lock:
            for rule_arn, priority in mapping.items():
                rule = self._rules_by_arn.get(rule_arn)
                if rule:
                    rule.priority = str(priority)

    def stop_listener(self, listener_arn: str) -> None:
        with self._lock:
            l4 = self.l4_listeners.pop(listener_arn, None)
            listener = self.listeners.pop(listener_arn, None)
            # Drop the rule table for this listener so a re-created listener
            # with the same ARN starts clean.
            for rule_arn in [
                r.arn for r in self.rules.get(listener_arn, [])
            ]:
                self._rules_by_arn.pop(rule_arn, None)
            self.rules.pop(listener_arn, None)
        if l4 is not None and l4.server_sock is not None:
            try:
                l4.server_sock.close()
            except Exception:
                LOG.debug("Error closing L4 listener %s", listener_arn, exc_info=True)
        if l4 is not None:
            self._refresh_dnat()
        if listener and listener.server:
            try:
                listener.server.shutdown()
                listener.server.server_close()
            except Exception:
                LOG.debug("Error stopping listener %s", listener_arn, exc_info=True)

    def _start_l4(
        self, lb_arn: str, listener_arn: str, protocol: str, requested_port: int,
        target_group_arn: str, scheme: str, vpc_networks: list[str],
        certificate_arn: Optional[str] = None,
    ) -> int:
        port = int(requested_port or 0)
        if port <= 0:
            LOG.warning("ELBv2 L4 listener %s has no port", listener_arn)
            return 0
        dest_ips = _dest_ips(scheme, vpc_networks)
        l4 = L4Listener(
            arn=listener_arn, lb_arn=lb_arn, protocol=protocol, port=port,
            target_group_arn=target_group_arn, scheme=scheme, dest_ips=dest_ips,
        )
        if protocol == "TLS":
            try:
                l4.ssl_ctx = _build_server_ssl_context(certificate_arn)
            except Exception as exc:
                LOG.warning("ELBv2 TLS listener %s has no cert: %s", listener_arn, exc)
                return 0
        bind_host = _bind_host(scheme, vpc_networks)
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((bind_host, port))
            sock.listen(128)
            sock.settimeout(1.0)
        except OSError as exc:
            LOG.warning("Could not bind L4 listener %s on %s:%s: %s", listener_arn, bind_host, port, exc)
            sock.close()
            return 0
        l4.server_sock = sock
        thread = threading.Thread(
            target=self._l4_accept, args=(l4,), name=f"elbv2-l4-{listener_arn[-8:]}",
            daemon=True,
        )
        thread.start()
        l4.thread = thread
        with self._lock:
            self.l4_listeners[listener_arn] = l4
        self._ensure_health_thread()
        if protocol == "TCP":
            self._refresh_dnat()
        self._publish_dns()
        LOG.info(
            "ELBv2 %s listener %s on %s:%s dests=%s",
            protocol, listener_arn, bind_host, port, ",".join(dest_ips) or "-",
        )
        return port

    def _l4_accept(self, l4: L4Listener) -> None:
        sock = l4.server_sock
        if sock is None:
            return
        while not self._stop.is_set():
            try:
                conn, _addr = sock.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(
                target=self._l4_handle, args=(l4, conn), daemon=True,
            ).start()

    def _l4_handle(self, l4: L4Listener, conn: socket.socket) -> None:
        upstream = None
        client = conn
        try:
            if l4.ssl_ctx is not None:
                client = l4.ssl_ctx.wrap_socket(conn, server_side=True)
            tg = self.target_groups.get(l4.target_group_arn)
            if tg is None:
                return
            _probe_group(tg)
            target = tg.pick_target()
            if target is None or not target.host:
                return
            upstream = socket.create_connection((target.host, target.port), timeout=10)
            _pipe_sockets(client, upstream)
        except Exception as exc:
            LOG.debug("ELBv2 L4 forward %s failed: %s", l4.arn, exc)
        finally:
            for sock_ in (client, upstream):
                if sock_ is None:
                    continue
                try:
                    sock_.close()
                except Exception:
                    pass

    def _refresh_dnat(self) -> None:
        """Install host-netns DNAT so NLB instance targets see the client source.

        Bridge traffic is conntracked on the host. DNAT there rewrites only
        the destination, and the reverse path puts the LB address back on
        the reply, so the target's accept() source is the caller.
        """
        with self._dnat_lock:
            with self._lock:
                listeners = [
                    l4 for l4 in self.l4_listeners.values() if l4.protocol == "TCP"
                ]
            rules: list[list[str]] = []
            for l4 in listeners:
                tg = self.target_groups.get(l4.target_group_arn)
                usable: list[Target] = []
                if tg is not None:
                    _probe_group(tg)
                    with tg._lock:
                        for t in tg.targets.values():
                            if t.host and t.health == "healthy":
                                usable.append(t)
                l4.dnat = False
                if not usable or not l4.dest_ips:
                    continue
                n = len(usable)
                for dip in l4.dest_ips:
                    for i, t in enumerate(usable):
                        rule = ["-d", dip, "-p", "tcp", "--dport", str(l4.port)]
                        if n > 1 and i < n - 1:
                            rule += [
                                "-m", "statistic", "--mode", "nth",
                                "--every", str(n - i), "--packet", "0",
                            ]
                        rule += ["-j", "DNAT", "--to-destination", f"{t.host}:{t.port}"]
                        rules.append(rule)
                l4.dnat = True
            sig = tuple(tuple(rule) for rule in rules)
            if sig == self._dnat_sig:
                return
            if not rules and not _sidecar_running():
                self._dnat_sig = sig
                return
            if not _iptables(["-t", "nat", "-S", _DNAT_CHAIN], quiet=True):
                if not _iptables(["-t", "nat", "-N", _DNAT_CHAIN], quiet=True):
                    LOG.warning("elbv2: host DNAT chain unavailable; TCP falls back to the proxy")
                    for l4 in listeners:
                        l4.dnat = False
                    return
            _iptables(["-t", "nat", "-F", _DNAT_CHAIN], quiet=True)
            for hook in ("PREROUTING", "OUTPUT"):
                if _iptables(
                    ["-t", "nat", "-C", hook, "-j", _DNAT_CHAIN], quiet=True,
                ):
                    continue
                if not _iptables(
                    ["-t", "nat", "-I", hook, "1", "-j", _DNAT_CHAIN],
                    quiet=True,
                ):
                    for l4 in listeners:
                        l4.dnat = False
                    return
            applied = True
            for rule in rules:
                if not _iptables(["-t", "nat", "-A", _DNAT_CHAIN, *rule], quiet=True):
                    LOG.warning("elbv2: DNAT rule failed: %s", rule)
                    applied = False
            if applied:
                self._dnat_sig = sig

    def _publish_dns(self) -> None:
        """Point LB DNS names at this process: VPC IP inside workloads, edge IP on the host.

        Also writes into *this* LocalEmu container's ``/etc/hosts`` so API Gateway
        ``HTTP_PROXY`` / VPC_LINK integrations can resolve ``*.elb.amazonaws.com``
        without a sidecar resolver (#267).
        """
        try:
            from localemu.utils.docker_utils import DOCKER_CLIENT
        except Exception:
            return
        with self._lock:
            lbs = list(self.load_balancers.values())
        host_lines = [_HOSTS_MARKER]
        workload: list[tuple[list[str], str, str]] = []
        self_entries: list[tuple[str, str]] = []
        for lb in lbs:
            dns = str(lb.get("dns_name") or "")
            if not dns:
                continue
            nets = [str(n) for n in (lb.get("vpc_networks") or [])]
            vpc_ip = ""
            for net in nets:
                ip = _join_network(net)
                if ip:
                    vpc_ip = ip
                    break
            scheme = str(lb.get("scheme") or "internet-facing").lower()
            edge = _edge_ip()
            if scheme == "internal":
                # Prefer the VPC address the listener binds on; fall back to
                # loopback so in-process clients (API GW) still resolve the name
                # when the VPC join has not finished yet.
                resolve_ip = vpc_ip or "127.0.0.1"
                host_lines.append(f"{resolve_ip} {dns}")
                self_entries.append((resolve_ip, dns))
                if vpc_ip:
                    workload.append((nets, vpc_ip, dns))
            else:
                if edge:
                    host_lines.append(f"{edge} {dns}")
                    self_entries.append((edge, dns))
                ip = vpc_ip or edge
                if ip:
                    workload.append((nets, ip, dns))
                    if not edge:
                        self_entries.append((ip, dns))
        try:
            os.makedirs(os.path.dirname(_HOSTS_PATH), exist_ok=True)
            with open(_HOSTS_PATH, "w", encoding="utf-8") as fh:
                fh.write("\n".join(host_lines) + "\n")
        except OSError:
            LOG.debug("elbv2 hosts file skipped", exc_info=True)
        _inject_self_hosts(self_entries)
        try:
            rows = DOCKER_CLIENT.list_containers(filter="label=localemu.service=ec2", all=False)
        except Exception:
            return
        for row in rows:
            name = str(row.get("name") or "").lstrip("/")
            if not name:
                continue
            try:
                cnets = set(DOCKER_CLIENT.get_networks(name))
            except Exception:
                continue
            for nets, ip, dns in workload:
                if nets and not cnets.intersection(nets):
                    continue
                script = (
                    "dns=" + _sh_quote(dns) + "; ip=" + _sh_quote(ip) + "; "
                    "cur=$(grep -vF \" $dns\" /etc/hosts || true); "
                    "printf '%s\\n%s %s\\n' \"$cur\" \"$ip\" \"$dns\" > /etc/hosts"
                )
                try:
                    DOCKER_CLIENT.exec_in_container(name, ["sh", "-c", script])
                except Exception:
                    LOG.debug("elbv2 hosts inject failed for %s", name, exc_info=True)

    # ------------ Health check loop ------------
    def _ensure_health_thread(self) -> None:
        if self._health_thread and self._health_thread.is_alive():
            return
        self._health_thread = threading.Thread(
            target=self._health_loop, name="elbv2-health", daemon=True,
        )
        self._health_thread.start()

    def _health_loop(self) -> None:
        while not self._stop.is_set():
            try:
                with self._lock:
                    tgs = list(self.target_groups.values())
                for tg in tgs:
                    with tg._lock:
                        targets = list(tg.targets.values())
                    for t in targets:
                        _resolve_target(t)
                        if not t.host:
                            if t.target_id.startswith("i-") and not t.lambda_arn:
                                t.health = "initial"
                            continue
                        ok = _tcp_ping(t.host, tg.health_check_port or t.port, timeout=1.5)
                        t.health = "healthy" if ok else "unhealthy"
                self._refresh_dnat()
                self._publish_dns()
            except Exception:
                LOG.debug("Health loop iteration error", exc_info=True)
            self._stop.wait(2.0)


_DNAT_CHAIN = "AWSBOX-ELBV2"
_SIDECAR = "awsbox-elbv2-iptables"
_HOSTS_PATH = "/var/lib/awsbox/elbv2.hosts"
_HOSTS_MARKER = "# awsbox-elbv2"
_joined_nets: set[str] = set()
_joined_lock = threading.Lock()


def _sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def _inject_self_hosts(entries: list[tuple[str, str]]) -> None:
    """Keep LocalEmu's own /etc/hosts in sync with published LB DNS names."""
    if not entries:
        return
    path = "/etc/hosts"
    try:
        with open(path, encoding="utf-8") as fh:
            existing = fh.read().splitlines()
    except OSError:
        LOG.debug("elbv2: cannot read %s", path, exc_info=True)
        return
    dns_names = {dns for _ip, dns in entries}
    kept: list[str] = []
    for line in existing:
        if line.strip() == _HOSTS_MARKER:
            continue
        names = line.split()[1:]
        if any(name in dns_names for name in names):
            continue
        kept.append(line)
    out = kept + [_HOSTS_MARKER] + [f"{ip} {dns}" for ip, dns in entries]
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(out) + "\n")
    except OSError:
        LOG.debug("elbv2: cannot write %s", path, exc_info=True)


def _instance_endpoint(instance_id: str) -> tuple[str, str]:
    try:
        from localemu.utils.docker_utils import DOCKER_CLIENT

        rows = DOCKER_CLIENT.list_containers(
            filter=f"label=localemu.instance-id={instance_id}", all=False,
        )
    except Exception:
        return "", ""
    if not rows:
        return "", ""
    name = str(rows[0].get("name") or "").lstrip("/")
    if not name:
        return "", ""
    try:
        nets = DOCKER_CLIENT.get_networks(name)
    except Exception:
        return "", ""
    for net in nets:
        if not str(net).startswith("localemu-vpc-"):
            continue
        try:
            ip = DOCKER_CLIENT.get_container_ipv4_for_network(name, net)
        except Exception:
            continue
        if ip:
            return str(ip), str(net)
    return "", ""


def _resolve_target(target: Target) -> None:
    if target.lambda_arn:
        return
    if target.target_id.startswith("i-"):
        host, net = _instance_endpoint(target.target_id)
        if host:
            target.host = host
        if net:
            _join_network(net)
    elif _looks_like_host(target.target_id) and not target.host:
        target.host = target.target_id


def _probe_group(tg: TargetGroup) -> None:
    with tg._lock:
        targets = list(tg.targets.values())
    for target in targets:
        _resolve_target(target)
        if not target.host:
            if target.target_id.startswith("i-") and not target.lambda_arn:
                target.health = "initial"
            continue
        ok = _tcp_ping(target.host, tg.health_check_port or target.port, timeout=1.0)
        target.health = "healthy" if ok else "unhealthy"


def _join_network(network: str) -> str:
    if not network:
        return ""
    try:
        from localemu.utils.docker_utils import DOCKER_CLIENT, get_current_container_id

        cid = get_current_container_id()
        nets = DOCKER_CLIENT.get_networks(cid)
        if network not in nets:
            DOCKER_CLIENT.connect_container_to_network(network, cid)
            with _joined_lock:
                _joined_nets.add(network)
        ip = DOCKER_CLIENT.get_container_ipv4_for_network(cid, network)
        return str(ip or "")
    except Exception:
        LOG.debug("elbv2: join %s failed", network, exc_info=True)
        return ""


def _leave_unused_networks(still_needed: set[str]) -> None:
    with _joined_lock:
        idle = [net for net in _joined_nets if net not in still_needed]
    if not idle:
        return
    try:
        from localemu.utils.docker_utils import DOCKER_CLIENT, get_current_container_id

        cid = get_current_container_id()
    except Exception:
        return
    for net in idle:
        try:
            DOCKER_CLIENT.disconnect_container_from_network(net, cid)
        except Exception:
            LOG.debug("elbv2: leave %s failed", net, exc_info=True)
            continue
        with _joined_lock:
            _joined_nets.discard(net)


def _edge_ip() -> str:
    try:
        from localemu.utils.docker_utils import DOCKER_CLIENT, get_current_container_id

        cid = get_current_container_id()
        nets = DOCKER_CLIENT.get_networks(cid)
    except Exception:
        return ""
    fallback = ""
    for net in nets:
        name = str(net)
        try:
            ip = str(DOCKER_CLIENT.get_container_ipv4_for_network(cid, name) or "")
        except Exception:
            continue
        if not ip or name.startswith("localemu-"):
            continue
        if name == "bridge":
            fallback = ip
            continue
        return ip
    return fallback


def _vpc_ips(vpc_networks: list[str]) -> list[str]:
    ips: list[str] = []
    for net in vpc_networks:
        ip = _join_network(net)
        if ip and ip not in ips:
            ips.append(ip)
    return ips


def _dest_ips(scheme: str, vpc_networks: list[str]) -> list[str]:
    vpc = _vpc_ips(vpc_networks)
    if (scheme or "").lower() == "internal":
        return vpc
    dests: list[str] = []
    edge = _edge_ip()
    if edge:
        dests.append(edge)
    for ip in vpc:
        if ip not in dests:
            dests.append(ip)
    return dests


def _bind_host(scheme: str, vpc_networks: list[str]) -> str:
    if (scheme or "").lower() == "internal":
        ips = _vpc_ips(vpc_networks)
        if ips:
            return ips[0]
        LOG.warning("elbv2: internal listener has no VPC address; binding 0.0.0.0")
    return "0.0.0.0"


def _docker_sdk():
    import docker

    return docker.from_env()


def _sidecar_running() -> bool:
    try:
        container = _docker_sdk().containers.get(_SIDECAR)
        container.reload()
        return container.status == "running"
    except Exception:
        return False


def _ensure_sidecar() -> bool:
    if _sidecar_running():
        return True
    try:
        # An exited sidecar from an earlier stack keeps the name; drop it before recreating.
        _docker_sdk().containers.get(_SIDECAR).remove(force=True)
    except Exception:
        pass
    try:
        _docker_sdk().containers.run(
            "localemu/ec2-base:v4",
            command=["infinity"],
            entrypoint="sleep",
            name=_SIDECAR,
            detach=True,
            privileged=True,
            network_mode="host",
            pid_mode="host",
            labels={"localemu.service": "elbv2-iptables"},
        )
        return True
    except Exception as exc:
        LOG.warning("elbv2 iptables sidecar: %s", exc)
        return False


def _iptables(args: list[str], quiet: bool = False) -> bool:
    if not _ensure_sidecar():
        return False
    try:
        container = _docker_sdk().containers.get(_SIDECAR)
        result = container.exec_run(
            ["nsenter", "-t", "1", "-m", "-n", "--", "iptables", *args],
        )
    except Exception as exc:
        if not quiet:
            LOG.warning("elbv2 iptables %s failed: %s", args, exc)
        return False
    if result.exit_code != 0:
        if not quiet:
            LOG.warning(
                "elbv2 iptables %s -> %s %s", args, result.exit_code, result.output,
            )
        return False
    return True


def _looks_like_host(s: str) -> bool:
    """Heuristic: return True if s looks like an IP or hostname (not an i-xxx instance id)."""
    if not s:
        return False
    if s.startswith("i-"):
        return False
    if "." in s or ":" in s:
        return True
    return False


# Singleton
_router_singleton: Optional[ListenerRouter] = None
_singleton_lock = threading.Lock()


def get_router() -> ListenerRouter:
    global _router_singleton
    if _router_singleton is not None:
        return _router_singleton
    with _singleton_lock:
        if _router_singleton is None:
            _router_singleton = ListenerRouter()
    return _router_singleton
