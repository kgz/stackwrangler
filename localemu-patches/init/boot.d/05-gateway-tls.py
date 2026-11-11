"""Install gateway CA/leaf into LocalEmu SSL cache before gateway bind (#687).

boot.d runs before ``_init_gateway_server``. Seeding ``server.test.pem`` here
makes LocalEmu's ``create_ssl_cert`` reuse our leaf (files already exist)
instead of minting a LocalEmu Org cert that tasks cannot verify.
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
    LOG.exception("gateway TLS boot install failed (#687)")
