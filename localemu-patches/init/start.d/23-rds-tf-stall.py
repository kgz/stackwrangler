"""Keep Terraform RDS create waiters from stalling after CreateDBInstance (#718).

Observed: ``terraform apply`` can sit ~55 minutes after ``CreateDBInstance``
with no ``localemu.request.aws`` completion lines, then three
``DescribeDBInstances`` 10s apart (Terraform's ContinuousTargetOccurence=3)
and finish. Request logs are completion-only unless receipt logging is on.

Hardening:
* Give each moto ``DBInstance`` a unique ``dbi_resource_id`` (stock moto
  hardcodes one value for every instance — breaks TF filter-by-resource-id).
* After Docker create succeeds, write ``available`` onto the moto backend
  object (not only the Create response dict).
* ``DescribeDBInstances`` copies endpoint/status from the in-memory Docker
  manager under a *timed* lock acquire so a stuck create/reconcile cannot
  block Describe for tens of minutes; never calls Docker on the describe path.
* ``get_instance_info`` stays lock-free (dict get) so Describe cannot wait on
  ``mgr._lock`` held across Docker start/wait in create/reboot/reconcile.
"""

from __future__ import annotations

import logging
import threading
import uuid

LOG = logging.getLogger("localemu.awsbox.rds_tf_stall")

_LOCK_WAIT_S = 2.0


def _unique_dbi_resource_id() -> str:
    # AWS shape: db- + uppercase alphanumeric. Keep filter-friendly.
    return "db-" + uuid.uuid4().hex[:22].upper()


def _try_lock(lock: threading.Lock | threading.RLock, timeout: float) -> bool:
    try:
        return bool(lock.acquire(timeout=timeout))
    except TypeError:
        return bool(lock.acquire(blocking=False))


def _sync_moto_available(context, db_id: str) -> None:
    if not db_id:
        return
    try:
        import moto.backends as moto_backends

        backend = moto_backends.get_backend("rds")[context.account_id][context.region]
        moto_db = backend.databases.get(db_id)
        if moto_db is None:
            return
        for attr in ("status", "db_instance_status"):
            if hasattr(moto_db, attr):
                try:
                    setattr(moto_db, attr, "available")
                except Exception:
                    pass
    except Exception:
        LOG.debug("rds tf-stall: moto status sync failed for %s", db_id, exc_info=True)


def _patch_unique_dbi_resource_id() -> None:
    from moto.rds.models import DBInstance

    if getattr(DBInstance, "_awsbox_unique_dbi_resource_id", False):
        return

    orig_init = DBInstance.__init__

    def __init__(self, *args, **kwargs):
        orig_init(self, *args, **kwargs)
        try:
            self.dbi_resource_id = _unique_dbi_resource_id()
        except Exception:
            LOG.debug("rds tf-stall: could not set unique dbi_resource_id", exc_info=True)

    DBInstance.__init__ = __init__
    DBInstance._awsbox_unique_dbi_resource_id = True


def _install() -> None:
    from localemu.services.moto import call_moto
    from localemu.services.rds import provider
    from localemu.services.rds.docker.db_manager import DockerDbManager

    if getattr(provider, "_awsbox_rds_tf_stall", False):
        return

    _patch_unique_dbi_resource_id()

    orig_create = provider._handle_create_db_instance
    orig_get_info = DockerDbManager.get_instance_info
    prev_dispatcher = provider.RdsDispatcher

    def get_instance_info(self, db_instance_id: str):
        """Lock-free read; never block Describe on a create/reconcile holder."""
        instances = getattr(self, "_instances", None)
        if not isinstance(instances, dict):
            return orig_get_info(self, db_instance_id)
        return instances.get(db_instance_id)

    def _handle_create_db_instance(context, request):
        result = orig_create(context, request)
        db_inst = (result or {}).get("DBInstance")
        if isinstance(db_inst, dict):
            db_id = db_inst.get("DBInstanceIdentifier")
            status = db_inst.get("DBInstanceStatus")
            if status == "available" and isinstance(db_id, str):
                _sync_moto_available(context, db_id)
        return result

    def _handle_describe_db_instances(context, request):
        result = call_moto(context)
        region = context.region or "us-east-1"
        mgr = provider._init_db_manager()
        if not mgr or not result.get("DBInstances"):
            return result

        lock = getattr(mgr, "_lock", None)
        raw = getattr(mgr, "_instances", None) or {}
        snapshot: dict = {}
        if lock is not None and callable(getattr(lock, "acquire", None)):
            if _try_lock(lock, _LOCK_WAIT_S):
                try:
                    snapshot = dict(raw)
                finally:
                    lock.release()
            else:
                LOG.warning(
                    "rds DescribeDBInstances: manager lock busy >%.1fs — "
                    "using lock-free snapshot (create/reconcile may be in flight)",
                    _LOCK_WAIT_S,
                )
                snapshot = dict(raw)
        else:
            snapshot = dict(raw)

        for db_inst in result["DBInstances"]:
            if not isinstance(db_inst, dict):
                continue
            db_id = db_inst.get("DBInstanceIdentifier")
            if not isinstance(db_id, str) or not db_id:
                continue
            info = snapshot.get(db_id)
            # Missing or create sentinel — leave moto status alone.
            if info is None or not getattr(info, "host_port", None):
                continue
            endpoint_address = provider._rds_endpoint_address(db_id, region)
            db_inst.setdefault("Endpoint", {})
            db_inst["Endpoint"]["Address"] = endpoint_address
            db_inst["Endpoint"]["Port"] = info.host_port
            status = getattr(info, "status", None) or "available"
            if status == "available":
                db_inst["DBInstanceStatus"] = "available"
                _sync_moto_available(context, db_id)
        return result

    def RdsDispatcherFactory(service_model):
        table = prev_dispatcher(service_model)
        table["CreateDBInstance"] = _handle_create_db_instance
        table["DescribeDBInstances"] = _handle_describe_db_instances
        return table

    DockerDbManager.get_instance_info = get_instance_info
    provider._handle_create_db_instance = _handle_create_db_instance
    provider._handle_describe_db_instances = _handle_describe_db_instances
    provider._INTERCEPTED_OPS["CreateDBInstance"] = _handle_create_db_instance
    provider._INTERCEPTED_OPS["DescribeDBInstances"] = _handle_describe_db_instances
    provider.RdsDispatcher = RdsDispatcherFactory

    # PERSISTENCE may have frozen the Skeleton dispatch table before start.d.
    try:
        from localemu.services.plugins import SERVICE_PLUGINS

        svc = SERVICE_PLUGINS.get_service("rds")
        skeleton = getattr(svc, "skeleton", None) if svc is not None else None
        table = getattr(skeleton, "dispatch_table", None)
        if isinstance(table, dict):
            table["CreateDBInstance"] = _handle_create_db_instance
            table["DescribeDBInstances"] = _handle_describe_db_instances
            LOG.info("rds tf-stall rebound live Create/Describe dispatch")
    except Exception:
        LOG.debug("rds tf-stall dispatch rebind skipped", exc_info=True)

    provider._awsbox_rds_tf_stall = True
    LOG.info("awsbox rds terraform-stall hardening applied")


_install()
