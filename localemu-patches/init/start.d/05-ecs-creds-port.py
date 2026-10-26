"""Pin the ECS task-credentials server to AWSBOX_ECS_CREDS_PORT (default 4571).

LocalEmu binds it to an ephemeral port inside this container. Host-network tasks
need a fixed port that compose publishes on host 127.0.0.1.
"""

from __future__ import annotations

import logging
import os
from http.server import ThreadingHTTPServer

LOG = logging.getLogger("localemu.awsbox.ecs_creds_port")


def _install() -> None:
    from localemu.services.ecs.docker import task_credentials as tc

    port = int(os.environ.get("AWSBOX_ECS_CREDS_PORT") or 4571)

    class FixedPortServer(ThreadingHTTPServer):
        def __init__(self, address, handler, *args, **kwargs):
            super().__init__((address[0], port), handler, *args, **kwargs)

    # task_credentials only builds the creds server with this name.
    tc.ThreadingHTTPServer = FixedPortServer
    LOG.info("awsbox ecs task-credentials port pinned to %d", port)


_install()
