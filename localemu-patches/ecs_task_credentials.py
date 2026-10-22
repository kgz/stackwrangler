"""ECS task role credentials endpoint (awsbox #79 / #252).

Host-mode tasks use AWS_CONTAINER_CREDENTIALS_FULL_URI on 127.0.0.1 (SDK
allow-listed) plus an Authorization token. Bridge/awsvpc keep RELATIVE_URI
+ in-container DNAT to this host-bound server.
"""
from __future__ import annotations

import json
import logging
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Optional

LOG = logging.getLogger(__name__)


class TaskCredentialStore:
    """Thread-safe in-memory store of ECS task-role credentials keyed by task_id."""

    def __init__(self) -> None:
        self._by_task: dict[str, dict] = {}
        self._auth: dict[str, str] = {}
        self._lock = threading.Lock()

    def put(self, task_id: str, creds: dict, auth_token: str | None = None) -> None:
        with self._lock:
            self._by_task[task_id] = dict(creds)
            if auth_token:
                self._auth[task_id] = auth_token
            else:
                self._auth.pop(task_id, None)

    def get(self, task_id: str) -> Optional[dict]:
        with self._lock:
            creds = self._by_task.get(task_id)
            return dict(creds) if creds else None

    def auth_token(self, task_id: str) -> Optional[str]:
        with self._lock:
            token = self._auth.get(task_id)
            return token

    def revoke(self, task_id: str) -> None:
        with self._lock:
            self._by_task.pop(task_id, None)
            self._auth.pop(task_id, None)

    def all_task_ids(self) -> list[str]:
        with self._lock:
            return list(self._by_task.keys())


class _TaskCredentialsHandler(BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        server: TaskCredentialsServer = self.server  # type: ignore[assignment]
        path = self.path.split("?", 1)[0].rstrip("/")

        if path.startswith("/v2/credentials/"):
            task_id = path[len("/v2/credentials/") :]
            expected = server.store.auth_token(task_id)
            if expected is not None:
                got = self.headers.get("Authorization") or ""
                if got != expected:
                    self.send_error(403, "Forbidden")
                    return
            creds = server.store.get(task_id)
            if not creds:
                self.send_error(404, "Credentials not found for this task")
                return
            body = json.dumps(creds).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if path.startswith("/v3/") or path.startswith("/v4/"):
            body = json.dumps(
                {
                    "Cluster": "default",
                    "TaskARN": "",
                    "Family": "",
                    "Revision": "1",
                }
            ).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_error(404, "Not found")

    def log_message(self, format, *args):  # noqa: A002
        LOG.debug("TaskCreds %s %s", self.client_address[0], format % args)


class TaskCredentialsServer:
    """HTTP server bound to 0.0.0.0 that serves ECS task creds.

    Prefer ``LOCALEMU_ECS_CREDS_PORT`` (compose publishes it on the host
    loopback) so host-networkMode tasks can use
    ``AWS_CONTAINER_CREDENTIALS_FULL_URI=http://127.0.0.1:<port>/…``.
    Falls back to an ephemeral port when unset.
    """

    def __init__(self) -> None:
        self.store = TaskCredentialStore()
        self._httpd: Optional[ThreadingHTTPServer] = None
        self._thread: Optional[threading.Thread] = None
        self._port: Optional[int] = None
        self._lock = threading.Lock()

    def start(self) -> int:
        with self._lock:
            if self._httpd is not None and self._port is not None:
                return self._port
            preferred = 0
            raw = os.environ.get("LOCALEMU_ECS_CREDS_PORT", "").strip()
            if raw.isdigit():
                preferred = int(raw)
            self._httpd = ThreadingHTTPServer(
                ("0.0.0.0", preferred), _TaskCredentialsHandler
            )
            self._httpd.store = self.store  # type: ignore[attr-defined]
            self._port = self._httpd.server_address[1]
            self._thread = threading.Thread(
                target=self._httpd.serve_forever,
                daemon=True,
                name="ecs-task-creds-server",
            )
            self._thread.start()
            LOG.info("ECS task credentials server listening on port %d", self._port)
            return self._port

    def stop(self) -> None:
        with self._lock:
            if self._httpd is not None:
                try:
                    self._httpd.shutdown()
                    self._httpd.server_close()
                except Exception:
                    LOG.debug("Failed to stop task creds server", exc_info=True)
                self._httpd = None
                self._port = None

    @property
    def port(self) -> Optional[int]:
        return self._port


_instance_lock = threading.Lock()
_instance: Optional[TaskCredentialsServer] = None


def get_task_credentials_server() -> TaskCredentialsServer:
    global _instance
    with _instance_lock:
        if _instance is None:
            _instance = TaskCredentialsServer()
            _instance.start()
        return _instance
