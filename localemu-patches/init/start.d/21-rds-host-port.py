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
import logging

LOG = logging.getLogger("localemu.awsbox.rds_host_port")

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


def _host_port_free(port: int) -> bool:
    from localemu.utils.net import port_can_be_bound

    try:
        from localemu.services.rds.provider import _init_db_manager

        mgr = _init_db_manager()
    except Exception:
        mgr = None
    if mgr is not None:
        for info in list(getattr(mgr, "_instances", {}).values()):
            if info is None:
                continue
            if getattr(info, "host_port", None) == port:
                return False
    return bool(port_can_be_bound(port))


def _ensure_host_port_free(port: int) -> None:
    if not _host_port_free(port):
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


def _install() -> None:
    from localemu.services.rds.docker import db_manager as db_manager_mod
    from localemu.services.rds.docker.db_manager import DockerDbManager
    from localemu.services.rds import provider
    from localemu.utils.net import dynamic_port_range, port_can_be_bound

    if getattr(DockerDbManager._do_create_db_instance, "_awsbox_host_port", False):
        return

    orig_get_free = db_manager_mod.get_free_tcp_port
    orig_do = DockerDbManager._do_create_db_instance
    orig_create_instance = provider._handle_create_db_instance
    orig_create_cluster = provider._handle_create_db_cluster
    orig_restore_one = provider._restore_one
    orig_dispatcher = provider.RdsDispatcher

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

    def _restore_one(mgr, db_id: str, moto_db, region: str) -> str:
        saved = _parse_port(getattr(moto_db, "port", None))
        orig_create = mgr.create_db_instance

        def create_db_instance(*args, port=None, **kwargs):
            use = _parse_port(port)
            if use is None:
                use = saved
            return orig_create(*args, port=use, **kwargs)

        mgr.create_db_instance = create_db_instance
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
    setattr(DockerDbManager._do_create_db_instance, "_awsbox_host_port", True)
    provider._handle_create_db_instance = _handle_create_db_instance
    provider._handle_create_db_cluster = _handle_create_db_cluster
    provider._restore_one = _restore_one
    provider._INTERCEPTED_OPS["CreateDBInstance"] = _handle_create_db_instance
    provider._INTERCEPTED_OPS["CreateDBCluster"] = _handle_create_db_cluster
    provider.RdsDispatcher = RdsDispatcher
    LOG.info("awsbox rds stable host-port patch applied")


_install()
