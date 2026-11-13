"""Stable, selectable RDS published host ports (#705).

LocalEmu's Docker RDS backend always called ``get_free_tcp_port()``, so
``Endpoint.Port`` changed after reboot / LocalEmu restart / persistence
recreate. This patch:

* treats CreateDBInstance / CreateDBCluster ``Port`` as the **published
  host** port (container listen port stays the engine default)
* accepts tag ``stackwrangler:host-port`` (or ``awsbox:host-port``) when
  ``Port`` is omitted
* errors clearly when the requested host port is taken
* reuses the first-assigned host port on persistence recreate via the
  moto-stored port
"""

from __future__ import annotations

import contextvars
import json
import logging
import os
from pathlib import Path

LOG = logging.getLogger("localemu.awsbox.rds_host_port")

_RDS_META_DIRNAME = "rds-host-port"

_PREFERRED_HOST_PORT: contextvars.ContextVar[int | None] = contextvars.ContextVar(
    "awsbox_rds_preferred_host_port",
    default=None,
)

# Set when allocate fails; Create* handlers swallow Exception into
# create-failed, so we surface a clear InvalidParameterValue after.
_PORT_ALLOC_ERROR: contextvars.ContextVar[int | None] = contextvars.ContextVar(
    "awsbox_rds_host_port_alloc_error",
    default=None,
)

_HOST_PORT_TAG_KEYS = ("stackwrangler:host-port", "awsbox:host-port")


class HostPortInUse(Exception):
    """Requested published host port cannot be bound."""

    def __init__(self, port: int):
        self.port = int(port)
        super().__init__(
            f"Host port {self.port} is already in use; "
            "choose a free port or omit --port / stackwrangler:host-port"
        )


def _request_get(request, name: str):
    if name in request:
        return request.get(name)
    for key, val in request.items():
        if isinstance(key, str) and key.lower() == name.lower():
            return val
    return None


def _parse_port(value: object) -> int | None:
    if value is None or value is False:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value if value > 0 else None
    if isinstance(value, str):
        text = value.strip()
        if not text or text.lower() in ("none", "null"):
            return None
        try:
            port = int(text)
        except ValueError:
            return None
        return port if port > 0 else None
    return None


def _iter_tag_pairs(request) -> list[tuple[str, str]]:
    raw = _request_get(request, "Tags")
    if raw is None:
        raw = _request_get(request, "TagList")
    if raw is None:
        return []
    if isinstance(raw, dict):
        # Query protocol sometimes nests members under a single dict.
        members = raw.get("Tag") or raw.get("member") or raw.get("Tags")
        if members is None:
            pairs: list[tuple[str, str]] = []
            key = raw.get("Key") or raw.get("key")
            val = raw.get("Value") or raw.get("value")
            if isinstance(key, str) and val is not None:
                pairs.append((key, str(val)))
            return pairs
        raw = members
    if not isinstance(raw, (list, tuple)):
        return []
    out: list[tuple[str, str]] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        key = item.get("Key") or item.get("key")
        val = item.get("Value") or item.get("value")
        if isinstance(key, str) and val is not None:
            out.append((key, str(val)))
    return out


def _tag_host_port(request) -> int | None:
    tags = {k.lower(): v for k, v in _iter_tag_pairs(request)}
    for key in _HOST_PORT_TAG_KEYS:
        if key in tags:
            return _parse_port(tags[key])
    return None


def _resolve_preferred_host_port(request) -> int | None:
    port = _parse_port(_request_get(request, "Port"))
    if port is not None:
        return port
    return _tag_host_port(request)


def _host_port_free(port: int, *, exclude_db_id: str | None = None) -> bool:
    from localemu.utils.net import port_can_be_bound

    try:
        from localemu.services.rds.provider import _init_db_manager

        mgr = _init_db_manager()
    except Exception:
        mgr = None
    if mgr is not None:
        for db_id, info in list(getattr(mgr, "_instances", {}).items()):
            if exclude_db_id is not None and db_id == exclude_db_id:
                continue
            if info is None:
                continue
            if getattr(info, "host_port", None) == port:
                return False
    return bool(port_can_be_bound(port))


def _ensure_host_port_free(port: int, *, exclude_db_id: str | None = None) -> None:
    if not _host_port_free(port, exclude_db_id=exclude_db_id):
        _PORT_ALLOC_ERROR.set(port)
        raise HostPortInUse(port)


def _raise_port_in_use(port: int):
    from localemu.aws.api import CommonServiceException as _CSE

    raise _CSE(
        "InvalidParameterValue",
        (
            f"Host port {port} is already in use; "
            "choose a free port or omit --port / stackwrangler:host-port"
        ),
        status_code=400,
    )


def _apply_preferred_to_request(request, preferred: int) -> None:
    # Moto + Docker create both read Port; we remap Port → published host
    # port inside _do_create (container listen stays engine default).
    request["Port"] = preferred


def _raise_if_port_alloc_failed(preferred: int | None):
    err = _PORT_ALLOC_ERROR.get()
    if err is not None:
        _raise_port_in_use(err)
    if preferred is None:
        return


def _meta_dir() -> Path | None:
    try:
        from localemu import config

        if not getattr(config, "PERSISTENCE", False):
            return None
        data = getattr(getattr(config, "dirs", None), "data", None)
        if not data:
            return None
        path = Path(str(data)) / _RDS_META_DIRNAME
        path.mkdir(parents=True, exist_ok=True)
        return path
    except Exception:
        LOG.debug("rds host-port meta dir unavailable", exc_info=True)
        return None


def _meta_path(db_id: str) -> Path | None:
    root = _meta_dir()
    if root is None:
        return None
    safe = "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in db_id)
    return root / f"{safe}.json"


def _write_instance_meta(info) -> None:
    path = _meta_path(getattr(info, "db_instance_id", "") or "")
    if path is None:
        LOG.debug("skip rds host-port meta write (persistence off or no data dir)")
        return
    payload = {
        "db_instance_id": info.db_instance_id,
        "host_port": int(info.host_port),
        "master_username": info.master_username,
        "master_password": info.master_password,
        "engine": info.engine,
        "db_name": info.db_name,
        "db_instance_class": info.db_instance_class,
        "vpc_id": info.vpc_id,
    }
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload), encoding="utf-8")
    os.replace(tmp, path)
    LOG.info("rds host-port meta saved %s port=%s", info.db_instance_id, info.host_port)


def _read_instance_meta(db_id: str) -> dict[str, object] | None:
    path = _meta_path(db_id)
    if path is None or not path.is_file():
        return None
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        LOG.debug("failed reading rds host-port meta for %s", db_id, exc_info=True)
        return None
    return raw if isinstance(raw, dict) else None


def _delete_instance_meta(db_id: str) -> None:
    path = _meta_path(db_id)
    if path is None:
        return
    try:
        path.unlink(missing_ok=True)
    except Exception:
        LOG.debug("failed deleting rds host-port meta for %s", db_id, exc_info=True)


def _install() -> None:
    from localemu.services.rds.docker import db_manager as db_manager_mod
    from localemu.services.rds.docker.db_manager import DockerDbManager
    from localemu.services.rds import provider
    from localemu.utils.net import dynamic_port_range, port_can_be_bound

    if getattr(DockerDbManager._do_create_db_instance, "_awsbox_host_port", False):
        return

    orig_get_free = db_manager_mod.get_free_tcp_port
    orig_do = DockerDbManager._do_create_db_instance
    orig_create_method = DockerDbManager.create_db_instance
    orig_delete_method = DockerDbManager.delete_db_instance
    orig_create_instance = provider._handle_create_db_instance
    orig_create_cluster = provider._handle_create_db_cluster
    orig_restore_one = provider._restore_one
    orig_dispatcher = provider.RdsDispatcher

    def create_db_instance(self, *args, **kwargs):
        info = orig_create_method(self, *args, **kwargs)
        try:
            _write_instance_meta(info)
        except Exception:
            LOG.debug("failed writing rds host-port meta", exc_info=True)
        return info

    def delete_db_instance(self, db_instance_id: str) -> None:
        try:
            orig_delete_method(self, db_instance_id)
        finally:
            _delete_instance_meta(db_instance_id)

    def _patched_get_free_tcp_port(blocklist=None):
        preferred = _PREFERRED_HOST_PORT.get()
        if preferred is not None:
            if not port_can_be_bound(preferred):
                _PORT_ALLOC_ERROR.set(preferred)
                raise HostPortInUse(preferred)
            try:
                dynamic_port_range.mark_reserved(preferred)
            except ValueError:
                pass
            return int(preferred)
        return orig_get_free(blocklist)

    def _do_create(self, db_instance_id, engine, *args, **kwargs):
        # Positional layout matches DockerDbManager._do_create_db_instance:
        # engine_version, master_username, master_password, db_name,
        # allocated_storage, db_instance_class, port, vpc_id, subnet_id=…
        port = kwargs.get("port") if "port" in kwargs else None
        if port is None and len(args) >= 7:
            port = args[6]
        preferred = _parse_port(port)
        if preferred is None:
            preferred = _PREFERRED_HOST_PORT.get()
        if preferred is not None:
            _ensure_host_port_free(preferred)

        token = _PREFERRED_HOST_PORT.set(preferred)
        try:
            # Force engine-default container listen port; Port means host.
            if "port" in kwargs:
                kwargs = dict(kwargs)
                kwargs["port"] = None
                return orig_do(self, db_instance_id, engine, *args, **kwargs)
            if len(args) >= 7:
                args_list = list(args)
                args_list[6] = None
                return orig_do(self, db_instance_id, engine, *args_list, **kwargs)
            return orig_do(self, db_instance_id, engine, *args, **kwargs)
        except HostPortInUse:
            raise
        finally:
            _PREFERRED_HOST_PORT.reset(token)

    def _handle_create_db_instance(context, request):
        err_token = _PORT_ALLOC_ERROR.set(None)
        preferred = _resolve_preferred_host_port(request)
        try:
            if preferred is not None:
                try:
                    _ensure_host_port_free(preferred)
                except HostPortInUse as exc:
                    _raise_port_in_use(exc.port)
                _apply_preferred_to_request(request, preferred)
            result = orig_create_instance(context, request)
            _raise_if_port_alloc_failed(preferred)
            return result
        except HostPortInUse as exc:
            _raise_port_in_use(exc.port)
        finally:
            _PORT_ALLOC_ERROR.reset(err_token)

    def _handle_create_db_cluster(context, request):
        err_token = _PORT_ALLOC_ERROR.set(None)
        preferred = _resolve_preferred_host_port(request)
        try:
            if preferred is not None:
                try:
                    _ensure_host_port_free(preferred)
                except HostPortInUse as exc:
                    _raise_port_in_use(exc.port)
                _apply_preferred_to_request(request, preferred)
            result = orig_create_cluster(context, request)
            _raise_if_port_alloc_failed(preferred)
            return result
        except HostPortInUse as exc:
            _raise_port_in_use(exc.port)
        finally:
            _PORT_ALLOC_ERROR.reset(err_token)

    def _recreate_from_meta(mgr, db_id: str, moto_db, region: str, held, meta) -> str:
        preferred = (
            _parse_port(getattr(moto_db, "port", None))
            or _parse_port(getattr(held, "host_port", None) if held else None)
            or _parse_port((meta or {}).get("host_port"))
        )
        master_pass = ""
        master_user = "admin"
        engine = getattr(moto_db, "engine", None) or "postgres"
        db_name = getattr(moto_db, "db_name", None)
        db_instance_class = getattr(moto_db, "db_instance_class", None) or "db.t3.micro"
        vpc_id = None
        if held is not None:
            master_pass = getattr(held, "master_password", "") or ""
            master_user = getattr(held, "master_username", None) or "admin"
            engine = getattr(held, "engine", None) or engine
            db_name = getattr(held, "db_name", None) or db_name
            db_instance_class = getattr(held, "db_instance_class", None) or db_instance_class
            vpc_id = getattr(held, "vpc_id", None)
        if meta:
            if not master_pass:
                pw = meta.get("master_password")
                master_pass = pw if isinstance(pw, str) else ""
            user = meta.get("master_username")
            if isinstance(user, str) and user:
                master_user = user
            eng = meta.get("engine")
            if isinstance(eng, str) and eng:
                engine = eng
            name = meta.get("db_name")
            if isinstance(name, str):
                db_name = name
            cls = meta.get("db_instance_class")
            if isinstance(cls, str) and cls:
                db_instance_class = cls
            vid = meta.get("vpc_id")
            if isinstance(vid, str):
                vpc_id = vid
        if not master_pass or preferred is None:
            return "failed"
        try:
            _ensure_host_port_free(preferred, exclude_db_id=db_id)
            info = mgr.create_db_instance(
                db_instance_id=db_id,
                engine=engine,
                engine_version=getattr(moto_db, "engine_version", None),
                master_username=master_user,
                master_password=master_pass,
                db_name=db_name,
                allocated_storage=getattr(moto_db, "allocated_storage", 20) or 20,
                db_instance_class=db_instance_class,
                port=preferred,
                vpc_id=vpc_id,
            )
            provider._patch_moto_endpoint(moto_db, region, info.host_port)
            for attr in ("status", "db_instance_status"):
                if hasattr(moto_db, attr):
                    try:
                        setattr(moto_db, attr, "available")
                    except Exception:
                        pass
            LOG.info("RDS %s recreated on stable host port %s", db_id, info.host_port)
            return "recreated"
        except Exception:
            LOG.warning("Stable-port recreate failed for RDS %s", db_id, exc_info=True)
            return "failed"

    def _restore_one(mgr, db_id: str, moto_db, region: str) -> str:
        from localemu.utils.docker_utils import DOCKER_CLIENT

        saved = _parse_port(getattr(moto_db, "port", None))
        name = mgr._container_name(db_id)
        container_gone = False
        try:
            DOCKER_CLIENT.inspect_container(name)
        except Exception:
            container_gone = True

        # Upstream create_db_instance refuses an id still in _instances, so
        # volume-recreate never runs when the manager still holds credentials.
        # Pop the stale entry, keep creds/port (memory or PERSISTENCE meta file).
        if container_gone:
            held = mgr.get_instance_info(db_id)
            meta = _read_instance_meta(db_id)
            with mgr._lock:
                mgr._instances.pop(db_id, None)
            if (held is not None and getattr(held, "master_password", None)) or meta:
                result = _recreate_from_meta(mgr, db_id, moto_db, region, held, meta)
                if result == "recreated":
                    return result
                if held is not None:
                    with mgr._lock:
                        mgr._instances.setdefault(db_id, held)
                return "failed"

        orig_create = mgr.create_db_instance

        def create_db_instance_wrapped(*args, port=None, **kwargs):
            use = _parse_port(port)
            if use is None:
                use = saved
            return orig_create(*args, port=use, **kwargs)

        mgr.create_db_instance = create_db_instance_wrapped
        try:
            return orig_restore_one(mgr, db_id, moto_db, region)
        finally:
            mgr.create_db_instance = orig_create

    def RdsDispatcher(service_model):
        table = orig_dispatcher(service_model)
        table["CreateDBInstance"] = _handle_create_db_instance
        table["CreateDBCluster"] = _handle_create_db_cluster
        return table

    db_manager_mod.get_free_tcp_port = _patched_get_free_tcp_port
    DockerDbManager._do_create_db_instance = _do_create
    DockerDbManager.create_db_instance = create_db_instance
    DockerDbManager.delete_db_instance = delete_db_instance
    setattr(DockerDbManager._do_create_db_instance, "_awsbox_host_port", True)
    provider._handle_create_db_instance = _handle_create_db_instance
    provider._handle_create_db_cluster = _handle_create_db_cluster
    provider._restore_one = _restore_one
    provider._INTERCEPTED_OPS["CreateDBInstance"] = _handle_create_db_instance
    provider._INTERCEPTED_OPS["CreateDBCluster"] = _handle_create_db_cluster
    provider.RdsDispatcher = RdsDispatcher
    LOG.info("awsbox rds stable host-port patch applied")

    # Persistence reconcile runs before start.d. Re-run now so volume recreate
    # can use the stable-port + meta-file path.
    try:
        provider._rds_on_after_state_load()
    except Exception:
        LOG.warning("rds host-port post-patch reconcile failed", exc_info=True)


_install()
