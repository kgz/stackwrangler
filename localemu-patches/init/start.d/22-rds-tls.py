"""Inject SAN'd MySQL server certs + publish RDS CA bundle (#765)."""

from __future__ import annotations

import logging
import sys

LOG = logging.getLogger("localemu.awsbox.rds_tls")

if "/opt/awsbox/tls" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/tls")


def _install() -> None:
    import awsbox_rds_tls as rds_tls
    from localemu.utils.docker_utils import DOCKER_CLIENT

    if getattr(DOCKER_CLIENT.create_container_from_config, "_awsbox_rds_tls", False):
        return

    try:
        rds_tls.ensure_rds_ca()
    except Exception:
        LOG.exception("rds TLS CA ensure failed (#765)")

    orig_create = DOCKER_CLIENT.create_container_from_config

    def create_container_from_config(container_config):
        labels = getattr(container_config, "labels", None) or {}
        if labels.get("localemu.service") == "rds":
            engine = labels.get("localemu.engine") or ""
            db_id = labels.get("localemu.db-instance-id") or ""
            if db_id and rds_tls.is_mysql_family(engine):
                try:
                    rds_tls.apply_mysql_tls(container_config, db_id)
                except Exception:
                    LOG.exception("rds TLS apply failed for %s", db_id)
        return orig_create(container_config)

    setattr(create_container_from_config, "_awsbox_rds_tls", True)
    DOCKER_CLIENT.create_container_from_config = create_container_from_config
    LOG.info("awsbox rds TLS patch applied (#765)")


try:
    _install()
except Exception:
    LOG.exception("rds TLS start install failed (#765)")
