"""Publish the RDS CA early so ``.awsbox/tls/rds-ca.pem`` exists before creates (#765)."""

import logging
import sys

LOG = logging.getLogger("localemu.awsbox.rds_tls")

if "/opt/awsbox/tls" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/tls")

try:
    from awsbox_rds_tls import ensure_rds_ca

    ensure_rds_ca()
except Exception:
    LOG.exception("rds TLS boot CA install failed (#765)")
