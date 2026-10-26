"""Start the VPCE private DNS resolver before the gateway drops NET_BIND_SERVICE."""

import os
import subprocess
import sys

_RESOLVER = "/opt/code/localemu/src/localemu/services/ec2/docker/vpce_private_dns.py"
_PY = "/opt/code/localemu/.venv/bin/python"

if os.path.isfile(_RESOLVER):
    log_fd = os.open(
        "/tmp/vpce-resolver.log",
        os.O_CREAT | os.O_APPEND | os.O_WRONLY,
        0o644,
    )
    subprocess.Popen(
        [_PY if os.path.isfile(_PY) else sys.executable, _RESOLVER, "serve"],
        start_new_session=True,
        stdout=log_fd,
        stderr=log_fd,
        close_fds=True,
    )
