"""RDS Docker restart policy under PERSISTENCE=1 (#763).

``up --dev`` already sets ``restart: unless-stopped`` on compose services.
RDS engine containers are created by LocalEmu (not compose) and defaulted to
``RestartPolicy: no``, so a host/Docker reboot left ``localemu-rds-*`` exited
even when LocalEmu itself came back.

When ``PERSISTENCE=1`` (dev mode):
* new RDS creates get ``unless-stopped`` after ``create_container_from_config``
* existing RDS containers are updated on boot (covers pre-#763 instances)

Ephemeral / test (``PERSISTENCE=0``) leaves the default ``no``.
"""

from __future__ import annotations

import logging
import os

LOG = logging.getLogger("localemu.awsbox.rds_restart_policy")

_RESTART_POLICY = {"Name": "unless-stopped"}


def _persistence_on() -> bool:
    try:
        from localemu import config

        if getattr(config, "PERSISTENCE", False):
            return True
    except Exception:
        LOG.debug("rds restart: config.PERSISTENCE unavailable", exc_info=True)
    return os.environ.get("PERSISTENCE", "0").strip() in ("1", "true", "True")


def _docker_sdk():
    from localemu.utils.docker_utils import DOCKER_CLIENT

    client_factory = getattr(DOCKER_CLIENT, "client", None)
    if callable(client_factory):
        return client_factory()
    return None


def _set_restart_unless_stopped(name_or_id: str) -> None:
    if not name_or_id:
        return
    try:
        sdk = _docker_sdk()
        if sdk is not None:
            sdk.containers.get(name_or_id).update(restart_policy=_RESTART_POLICY)
            return
    except Exception:
        LOG.debug(
            "rds restart: SDK update failed for %s", name_or_id, exc_info=True
        )
    try:
        import subprocess

        subprocess.run(
            ["docker", "update", "--restart=unless-stopped", name_or_id],
            check=False,
            capture_output=True,
            timeout=30,
        )
    except Exception:
        LOG.debug(
            "rds restart: docker update failed for %s", name_or_id, exc_info=True
        )


def _reconcile_existing() -> None:
    """Apply policy to any RDS containers already on the host."""
    try:
        sdk = _docker_sdk()
        if sdk is None:
            return
        for ctr in sdk.containers.list(
            all=True, filters={"label": "localemu.service=rds"}
        ):
            try:
                name = (ctr.name or "").lstrip("/")
                policy = (ctr.attrs.get("HostConfig") or {}).get("RestartPolicy") or {}
                if policy.get("Name") == "unless-stopped":
                    continue
                _set_restart_unless_stopped(name or ctr.id)
                LOG.info("rds restart: set unless-stopped on %s (#763)", name or ctr.id)
            except Exception:
                LOG.debug("rds restart: reconcile one failed", exc_info=True)
    except Exception:
        LOG.debug("rds restart: reconcile list failed", exc_info=True)


def _install() -> None:
    from localemu.utils.docker_utils import DOCKER_CLIENT

    if not _persistence_on():
        LOG.info("rds restart: PERSISTENCE off — leave RestartPolicy=no (#763)")
        return

    if getattr(DOCKER_CLIENT.create_container_from_config, "_awsbox_rds_restart", False):
        _reconcile_existing()
        return

    orig_create = DOCKER_CLIENT.create_container_from_config

    def create_container_from_config(container_config):
        labels = getattr(container_config, "labels", None) or {}
        cid = orig_create(container_config)
        if labels.get("localemu.service") == "rds":
            name = getattr(container_config, "name", None) or cid
            try:
                _set_restart_unless_stopped(name)
                LOG.info("rds restart: set unless-stopped on create %s (#763)", name)
            except Exception:
                LOG.exception("rds restart: create update failed for %s", name)
        return cid

    setattr(create_container_from_config, "_awsbox_rds_restart", True)
    DOCKER_CLIENT.create_container_from_config = create_container_from_config
    _reconcile_existing()
    LOG.info("awsbox rds restart policy patch applied (#763)")


try:
    _install()
except Exception:
    LOG.exception("rds restart policy start install failed (#763)")
