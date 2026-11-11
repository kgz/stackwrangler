"""Idempotent gateway TLS ensure after infra start (#687).

boot.d/05-gateway-tls.py does the pre-gateway install. This start.d copy
reuses the stable CA (no remint) so a late SAN refresh still updates
``.awsbox`` material for the next boot / task mounts.
"""

import logging
import sys

LOG = logging.getLogger("localemu.awsbox.gateway_tls")

if "/opt/awsbox/tls" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/tls")

try:
    from awsbox_gateway_tls import ensure_gateway_tls

    ensure_gateway_tls()
except Exception:
    LOG.exception("gateway TLS setup failed (#687)")
