"""Apply RDS DB / cluster parameter groups to Docker DB containers (#703).

Moto accepts Create/ModifyDBParameterGroup (and cluster variants) but
DockerDbManager always starts MySQL/Postgres at image defaults. This
startup patch:

* resolves user-set parameters from the moto backend at CreateDBInstance /
  CreateDBCluster time and injects them into the container CMD
  (``--name=value`` for MySQL, ``-c name=value`` for Postgres)
* after ``RebootDBInstance``, re-applies the current group via
  ``SET GLOBAL`` / ``ALTER SYSTEM`` + ``pg_reload_conf``
"""

from __future__ import annotations

import contextvars
import logging
import re
import shlex
import time

LOG = logging.getLogger("localemu.awsbox.rds_param_groups")

_PENDING: contextvars.ContextVar[dict[str, str] | None] = contextvars.ContextVar(
    "awsbox_rds_pending_params",
    default=None,
)
_FORCE_HOST_PORT: contextvars.ContextVar[int | None] = contextvars.ContextVar(
    "awsbox_rds_force_host_port",
    default=None,
)

_SKIP_NAMES = frozenset(
    {
        "server-id",
        "server_id",
        "log-bin",
        "log_bin",
        "binlog-format",
        "binlog_format",
        "relay-log",
        "relay_log",
        "bind-address",
        "bind_address",
        "default-authentication-plugin",
        "default_authentication_plugin",
        "wal_level",
        "max_wal_senders",
        "max_replication_slots",
        "hot_standby",
        "listen_addresses",
        "wal_keep_size",
    }
)


def _is_mysql(engine: str) -> bool:
    e = (engine or "").lower()
    return e in ("mysql", "mariadb") or e.startswith("aurora-mysql")


def _is_postgres(engine: str) -> bool:
    e = (engine or "").lower()
    return e == "postgres" or e.startswith("aurora-postgresql")


def _request_get(request, *names: str) -> object:
    for name in names:
        if name in request:
            return request.get(name)
        for key, val in request.items():
            if isinstance(key, str) and key.lower() == name.lower():
                return val
    return None


def _rds_backend(account_id: str, region: str):
    import moto.backends as moto_backends

    return moto_backends.get_backend("rds")[account_id][region]


def _user_parameters(group) -> dict[str, str]:
    out: dict[str, str] = {}
    raw = getattr(group, "parameters", None) or {}
    for name, meta in raw.items():
        if not isinstance(name, str) or not name:
            continue
        if name.lower() in _SKIP_NAMES:
            continue
        if not isinstance(meta, dict) or "ParameterValue" not in meta:
            continue
        val = meta.get("ParameterValue")
        if val is None:
            continue
        out[name] = str(val)
    return out


def _group_params(backend, name: str, *, cluster: bool) -> dict[str, str]:
    if not name:
        return {}
    store = (
        backend.db_cluster_parameter_groups
        if cluster
        else backend.db_parameter_groups
    )
    group = store.get(name) or store.get(name.lower())
    if group is None:
        return {}
    return _user_parameters(group)


def _params_for_cluster(backend, cluster_id: str) -> dict[str, str]:
    cluster = backend.clusters.get(cluster_id)
    if cluster is None:
        return {}
    pg_name = getattr(cluster, "parameter_group", None) or ""
    if not pg_name or str(pg_name).startswith("default."):
        return {}
    return _group_params(backend, str(pg_name), cluster=True)


def _params_for_instance(backend, db_instance_id: str) -> dict[str, str]:
    db = backend.databases.get(db_instance_id)
    if db is None:
        return {}
    cid = getattr(db, "db_cluster_identifier", None)
    if cid:
        params = _params_for_cluster(backend, str(cid))
        if params:
            return params
    pg_name = getattr(db, "db_parameter_group_name", None) or ""
    if not pg_name:
        return {}
    if hasattr(db, "is_default_parameter_group") and db.is_default_parameter_group(
        pg_name
    ):
        return {}
    if str(pg_name).startswith("default."):
        return {}
    return _group_params(backend, str(pg_name), cluster=False)


def _lookup_parameters(
    db_instance_id: str,
    cluster_id: str | None = None,
    *,
    account_id: str | None = None,
    region: str | None = None,
) -> dict[str, str]:
    pending = _PENDING.get()
    if pending is not None:
        return pending

    try:
        from moto.rds.models import rds_backends
    except Exception:
        return {}

    backends: list[object] = []
    if account_id and region:
        try:
            backends.append(_rds_backend(account_id, region))
        except Exception:
            pass
    try:
        for _acc, _reg, backend in rds_backends.iter_backends():
            backends.append(backend)
    except Exception:
        pass

    for backend in backends:
        try:
            if cluster_id:
                params = _params_for_cluster(backend, cluster_id)
                if params:
                    return params
            if db_instance_id:
                if hasattr(backend, "clusters") and db_instance_id in backend.clusters:
                    params = _params_for_cluster(backend, db_instance_id)
                    if params:
                        return params
                params = _params_for_instance(backend, db_instance_id)
                if params:
                    return params
        except Exception as exc:
            LOG.debug("rds param lookup failed: %s", exc, exc_info=True)
    return {}


def _resolve_create_params(context, request, *, cluster: bool) -> dict[str, str]:
    account_id = getattr(context, "account_id", None) or "000000000000"
    region = getattr(context, "region", None) or "us-east-1"
    try:
        backend = _rds_backend(str(account_id), str(region))
    except Exception as exc:
        LOG.warning("rds param groups: backend unavailable: %s", exc)
        return {}

    if cluster:
        name = _request_get(request, "DBClusterParameterGroupName")
        if isinstance(name, str) and name and not name.startswith("default."):
            return _group_params(backend, name, cluster=True)
        return {}

    cid = _request_get(request, "DBClusterIdentifier")
    if isinstance(cid, str) and cid:
        params = _params_for_cluster(backend, cid)
        if params:
            return params

    name = _request_get(request, "DBParameterGroupName")
    if isinstance(name, str) and name and not name.startswith("default."):
        return _group_params(backend, name, cluster=False)
    return {}


def _mysql_cli_args(params: dict[str, str]) -> list[str]:
    return [f"--{name.replace('_', '-')}={value}" for name, value in params.items()]


def _postgres_cli_args(params: dict[str, str]) -> list[str]:
    args: list[str] = []
    for name, value in params.items():
        args.extend(["-c", f"{name}={value}"])
    return args


def _inject_mysql_reader_flags(script: str, flags: list[str]) -> str:
    """Insert mysqld flags after the reader bootstrap's mysqld invocation.

    ``20-rds-mysql`` builds the reader script with Python line-continuations, so
    the shell text is a single ``docker-entrypoint.sh mysqld --server-id=…``
    line (no trailing ``\\``).
    """
    if not flags:
        return script
    flag_str = " " + " ".join(flags)
    replaced, n = re.subn(
        r"(docker-entrypoint\.sh mysqld)",
        rf"\1{flag_str}",
        script,
        count=1,
    )
    if n:
        return replaced
    replaced, n = re.subn(
        r"(^mysqld)\b",
        rf"\1{flag_str}",
        script,
        count=1,
        flags=re.M,
    )
    return replaced if n else script


def _apply_params_to_command(
    command: list[str] | None,
    engine: str,
    params: dict[str, str],
) -> list[str] | None:
    if not params:
        return command
    if _is_mysql(engine):
        extra = _mysql_cli_args(params)
        if command is None:
            return ["mysqld", *extra]
        if command and command[0] == "mysqld":
            return [*command, *extra]
        if (
            command
            and command[0] == "bash"
            and len(command) >= 3
            and isinstance(command[2], str)
        ):
            return ["bash", "-c", _inject_mysql_reader_flags(command[2], extra)]
        return command
    if _is_postgres(engine):
        extra = _postgres_cli_args(params)
        if command is None:
            return ["postgres", *extra]
        if command and command[0] == "postgres":
            return [*command, *extra]
        if (
            command
            and command[0] == "bash"
            and len(command) >= 3
            and isinstance(command[2], str)
        ):
            script = command[2]
            joined = " ".join(shlex.quote(a) for a in extra)
            if "exec postgres" in script and joined:
                script = script.replace("exec postgres", f"exec postgres {joined}", 1)
            return ["bash", "-c", script]
        return command
    return command


def _mysql_quote(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def _mysql_set_literal(value: str) -> str:
    # Integers/floats must be bare (SET GLOBAL max_connections=75).
    if re.fullmatch(r"-?\d+(\.\d+)?", value or ""):
        return value
    return _mysql_quote(value)


def _pg_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def _exec_sql(
    container: str, engine: str, username: str, password: str, sql: str
) -> None:
    from localemu.utils.docker_utils import DOCKER_CLIENT

    if _is_mysql(engine):
        script = (
            'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; '
            "mysql --protocol=tcp -h 127.0.0.1 -uroot -N -e "
            + shlex.quote(sql)
        )
        DOCKER_CLIENT.exec_in_container(container, ["bash", "-c", script])
        return
    cmd = [
        "psql",
        "-h",
        "127.0.0.1",
        "-U",
        username,
        "-d",
        "postgres",
        "-v",
        "ON_ERROR_STOP=1",
        "-c",
        sql,
    ]
    DOCKER_CLIENT.exec_in_container(
        container,
        cmd,
        env_vars={"PGPASSWORD": password or ""},
    )


def _apply_params_sql(info, params: dict[str, str]) -> None:
    if not params:
        return
    container = info.container_name
    engine = info.engine or ""
    deadline = time.time() + 60
    last = ""
    while time.time() < deadline:
        try:
            if _is_mysql(engine):
                for name, value in params.items():
                    _exec_sql(
                        container,
                        engine,
                        info.master_username,
                        info.master_password,
                        f"SET GLOBAL {name}={_mysql_set_literal(value)}",
                    )
            elif _is_postgres(engine):
                for name, value in params.items():
                    _exec_sql(
                        container,
                        engine,
                        info.master_username,
                        info.master_password,
                        f"ALTER SYSTEM SET {name} = {_pg_quote(value)}",
                    )
                _exec_sql(
                    container,
                    engine,
                    info.master_username,
                    info.master_password,
                    "SELECT pg_reload_conf()",
                )
            else:
                return
            LOG.info(
                "rds param groups: applied %s on %s after reboot",
                sorted(params),
                info.db_instance_id,
            )
            return
        except Exception as exc:
            last = str(exc)
            time.sleep(2)
    LOG.warning(
        "rds param groups: failed to apply on %s: %s",
        info.db_instance_id,
        last,
    )


def _install() -> None:
    from localemu.services.rds import provider
    from localemu.services.rds.docker.db_manager import DockerDbManager
    from localemu.utils.docker_utils import DOCKER_CLIENT

    if getattr(DOCKER_CLIENT.create_container_from_config, "_awsbox_rds_pg", False):
        return

    # Bind on the singleton instance — class-level patches on ContainerClient
    # are easy to miss when SdkDockerClient is already constructed.
    orig_create = DOCKER_CLIENT.create_container_from_config
    orig_reboot = DockerDbManager.reboot_db_instance
    orig_create_instance = provider._handle_create_db_instance
    orig_create_cluster = provider._handle_create_db_cluster
    orig_dispatcher = provider.RdsDispatcher

    def create_container_from_config(container_config):
        labels = getattr(container_config, "labels", None) or {}
        if labels.get("localemu.service") == "rds":
            engine = labels.get("localemu.engine") or ""
            db_id = labels.get("localemu.db-instance-id") or ""
            cluster_id = labels.get("localemu.cluster-id") or None
            params = _lookup_parameters(db_id, cluster_id)
            LOG.info(
                "rds param groups: create %s engine=%s pending=%s params=%s",
                db_id,
                engine,
                _PENDING.get() is not None,
                sorted(params) if params else [],
            )
            if params:
                before = getattr(container_config, "command", None)
                container_config.command = _apply_params_to_command(
                    before, engine, params
                )
                LOG.info(
                    "rds param groups: %s cmd=%s",
                    db_id,
                    container_config.command,
                )
        return orig_create(container_config)

    def reboot_db_instance(self, db_instance_id: str) -> None:
        info = self.get_instance_info(db_instance_id)
        params = _lookup_parameters(
            db_instance_id,
            getattr(info, "cluster_id", None) if info is not None else None,
        )
        # MySQL: docker restart then SET GLOBAL (CLI values are overridden).
        if info is not None and _is_mysql(info.engine or ""):
            orig_reboot(self, db_instance_id)
            try:
                _apply_params_sql(info, params)
            except Exception as exc:
                LOG.warning(
                    "rds param groups: reboot apply failed for %s: %s",
                    db_instance_id,
                    exc,
                )
            return

        # Postgres: ``-c`` on the container CMD outranks ALTER SYSTEM, so
        # refresh the container with the current parameter group.
        if info is not None and _is_postgres(info.engine or "") and params:
            from localemu.utils.docker_utils import DOCKER_CLIENT

            name = info.container_name
            try:
                DOCKER_CLIENT.stop_container(name, timeout=10)
            except Exception:
                pass
            try:
                DOCKER_CLIENT.remove_container(name)
            except Exception:
                pass
            with self._lock:
                self._instances.pop(db_instance_id, None)
            token_port = _FORCE_HOST_PORT.set(int(info.host_port))
            token_params = _PENDING.set(params)
            try:
                self.create_db_instance(
                    db_instance_id=info.db_instance_id,
                    engine=info.engine,
                    master_username=info.master_username,
                    master_password=info.master_password,
                    db_name=info.db_name,
                    db_instance_class=info.db_instance_class,
                    vpc_id=info.vpc_id,
                    cluster_id=info.cluster_id,
                    is_writer=info.is_writer,
                    promotion_tier=info.promotion_tier,
                )
                LOG.info(
                    "rds param groups: recreated %s with params %s",
                    db_instance_id,
                    sorted(params),
                )
            except Exception as exc:
                LOG.warning(
                    "rds param groups: recreate on reboot failed for %s: %s",
                    db_instance_id,
                    exc,
                )
                orig_reboot(self, db_instance_id)
            finally:
                _FORCE_HOST_PORT.reset(token_port)
                _PENDING.reset(token_params)
            return

        orig_reboot(self, db_instance_id)
        if info is not None:
            try:
                _apply_params_sql(info, params)
            except Exception as exc:
                LOG.warning(
                    "rds param groups: reboot apply failed for %s: %s",
                    db_instance_id,
                    exc,
                )

    def _with_pending(context, request, *, cluster: bool, call):
        params = _resolve_create_params(context, request, cluster=cluster)
        LOG.info(
            "rds param groups: pending %s cluster=%s keys=%s",
            "cluster" if cluster else "instance",
            cluster,
            sorted(params) if params else [],
        )
        token = _PENDING.set(params)
        try:
            return call(context, request)
        finally:
            _PENDING.reset(token)

    def _handle_create_db_instance(context, request):
        return _with_pending(
            context, request, cluster=False, call=orig_create_instance
        )

    def _handle_create_db_cluster(context, request):
        return _with_pending(
            context, request, cluster=True, call=orig_create_cluster
        )

    def RdsDispatcher(service_model):
        table = orig_dispatcher(service_model)
        table["CreateDBInstance"] = _handle_create_db_instance
        table["CreateDBCluster"] = _handle_create_db_cluster
        return table

    # Preserve host port across postgres recreate-on-reboot.
    import localemu.services.rds.docker.db_manager as db_manager_mod

    orig_free_port = db_manager_mod.get_free_tcp_port

    def get_free_tcp_port():
        forced = _FORCE_HOST_PORT.get()
        if forced is not None:
            return int(forced)
        return orig_free_port()

    setattr(create_container_from_config, "_awsbox_rds_pg", True)
    DOCKER_CLIENT.create_container_from_config = create_container_from_config
    DockerDbManager.reboot_db_instance = reboot_db_instance
    db_manager_mod.get_free_tcp_port = get_free_tcp_port
    provider._handle_create_db_instance = _handle_create_db_instance
    provider._handle_create_db_cluster = _handle_create_db_cluster
    provider._INTERCEPTED_OPS["CreateDBInstance"] = _handle_create_db_instance
    provider._INTERCEPTED_OPS["CreateDBCluster"] = _handle_create_db_cluster
    provider.RdsDispatcher = RdsDispatcher
    LOG.info("awsbox rds param groups patch applied")


_install()
