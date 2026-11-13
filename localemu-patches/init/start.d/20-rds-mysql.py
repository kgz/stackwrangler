"""Aurora MySQL writer/reader containers and RDS-managed master secrets.

LocalEmu already maps ``mysql`` / ``aurora-mysql`` onto MySQL images, but
cluster members skip binlog replication and ``ManageMasterUserPassword``
stores a fixed ``admin`` / ``P@55w0rd!`` secret that the container never
uses. This startup patch:

* boots a cluster writer with binary logging and a replication user
* boots readers that clone the app database and stay ``super_read_only``
* writes the real username and password into the ``rds!`` secret
* overwrites cluster endpoint host/port (moto pre-fills the AWS hostname)
"""

from __future__ import annotations

import contextvars
import json
import logging
import shlex
import time
import uuid
import zlib

LOG = logging.getLogger("localemu.awsbox.rds_mysql")

_CTX: contextvars.ContextVar[dict[str, object] | None] = contextvars.ContextVar(
    "awsbox_rds_mysql_ctx",
    default=None,
)


def _is_mysql(engine: str) -> bool:
    e = (engine or "").lower()
    return e == "mysql" or e == "mariadb" or e.startswith("aurora-mysql")


def _safe_password(length: int = 24) -> str:
    """Alphanumeric so the MySQL image entrypoint can quote it."""
    import secrets
    import string

    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _truthy(value: object) -> bool:
    if value is True or value == 1:
        return True
    if isinstance(value, str) and value.lower() in ("true", "1"):
        return True
    return False


def _request_flag(request, name: str) -> object:
    if name in request:
        return request.get(name)
    for key, val in request.items():
        if isinstance(key, str) and key.lower() == name.lower():
            return val
    return None


def _default_gateway() -> str:
    try:
        with open("/proc/net/route", encoding="utf-8") as fh:
            for line in fh.readlines()[1:]:
                fields = line.split()
                if len(fields) < 3 or fields[1] != "00000000":
                    continue
                raw = fields[2]
                return ".".join(str(int(raw[i : i + 2], 16)) for i in (6, 4, 2, 0))
    except Exception:
        return ""
    return ""


def _ctx_engine() -> str:
    ctx = _CTX.get()
    if not ctx:
        return ""
    engine = ctx.get("engine")
    return engine if isinstance(engine, str) else ""


def _server_id(instance_id: str) -> int:
    return 2 + (zlib.crc32(instance_id.encode()) % 1_000_000)


def _mysql_exec(container: str, sql: str) -> tuple[bytes, bytes]:
    from localemu.utils.docker_utils import DOCKER_CLIENT

    script = (
        'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"; '
        "mysql --protocol=tcp -h 127.0.0.1 -uroot -N -e "
        + shlex.quote(sql)
    )
    return DOCKER_CLIENT.exec_in_container(container, ["bash", "-c", script])


def _mysql_writer_init(container: str, repl_user: str, repl_password: str) -> None:
    sql = (
        f"CREATE USER IF NOT EXISTS '{repl_user}'@'%' "
        f"IDENTIFIED WITH mysql_native_password BY '{repl_password}'; "
        f"ALTER USER '{repl_user}'@'%' "
        f"IDENTIFIED WITH mysql_native_password BY '{repl_password}'; "
        "GRANT REPLICATION SLAVE, REPLICATION CLIENT ON *.* "
        f"TO '{repl_user}'@'%'; FLUSH PRIVILEGES;"
    )
    deadline = time.time() + 90
    last = ""
    while time.time() < deadline:
        try:
            _mysql_exec(container, sql)
            LOG.info("mysql writer %s replication user ready", container)
            return
        except Exception as exc:
            last = str(exc)
            time.sleep(2)
    LOG.warning("mysql writer %s replication user not created: %s", container, last)


def _wait_mysql_reader(container: str, timeout: int) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            out, _err = _mysql_exec(container, "SELECT @@global.super_read_only")
            if out.decode(errors="replace").strip() == "1":
                return True
        except Exception:
            pass
        time.sleep(2)
    return False


def _reader_shell(
    writer_alias: str,
    port: int,
    repl_user: str,
    repl_password: str,
    server_id: int,
) -> str:
    w = shlex.quote(writer_alias)
    user = shlex.quote(repl_user)
    pw = shlex.quote(repl_password)
    sql_pw = repl_password.replace("'", "''")
    sql_user = repl_user.replace("'", "''")
    # Shell text, not a Python format string: keep backslash-n as two chars.
    nl = "\\n"
    return f"""set -eu
root() {{ MYSQL_PWD="$MYSQL_ROOT_PASSWORD" "$@"; }}
echo '[awsbox] mysql reader waiting for writer {writer_alias}'
deadline=$(( $(date +%s) + 180 ))
until root mysqladmin --protocol=tcp -h {w} -P {int(port)} -uroot ping --silent; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo '[awsbox] writer never accepted connections' >&2
    exit 1
  fi
  sleep 2
done
until MYSQL_PWD={pw} mysql --protocol=tcp -h {w} -P {int(port)} -u {user} -e 'SELECT 1' >/dev/null 2>&1; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo '[awsbox] replication user never authenticated' >&2
    exit 1
  fi
  sleep 2
done
echo '[awsbox] mysql reader starting local server'
docker-entrypoint.sh mysqld \
  --server-id={int(server_id)} \
  --relay-log=relay-bin \
  --bind-address=0.0.0.0 \
  --default-authentication-plugin=mysql_native_password &
pid=$!
deadline=$(( $(date +%s) + 180 ))
until root mysqladmin --protocol=tcp -h 127.0.0.1 -uroot ping --silent; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo '[awsbox] local mysqld did not come up' >&2
    exit 1
  fi
  sleep 2
done
db="${{MYSQL_DATABASE:-main}}"
echo "[awsbox] cloning $db from writer"
root mysqldump --protocol=tcp -h {w} -P {int(port)} -uroot \
  --single-transaction --source-data=2 --set-gtid-purged=OFF \
  --databases "$db" > /tmp/awsbox-mysql.dump
line=$(grep -E 'CHANGE (REPLICATION SOURCE|MASTER) TO' /tmp/awsbox-mysql.dump | head -1 || true)
file=$(printf '%s{nl}' "$line" | sed -n "s/.*\\(SOURCE_LOG_FILE\\|MASTER_LOG_FILE\\)='\\([^']*\\)'.*/\\2/p")
pos=$(printf '%s{nl}' "$line" | sed -n "s/.*\\(SOURCE_LOG_POS\\|MASTER_LOG_POS\\)=\\([0-9][0-9]*\\).*/\\2/p")
if [ -z "$file" ] || [ -z "$pos" ]; then
  echo '[awsbox] dump has no binlog position' >&2
  printf '%s{nl}' "$line" >&2
  exit 1
fi
echo "[awsbox] replica source $file:$pos"
root mysql --protocol=tcp -h 127.0.0.1 -uroot < /tmp/awsbox-mysql.dump
root mysql --protocol=tcp -h 127.0.0.1 -uroot -e "STOP REPLICA; RESET REPLICA ALL;" || true
root mysql --protocol=tcp -h 127.0.0.1 -uroot -e "CHANGE REPLICATION SOURCE TO SOURCE_HOST='{writer_alias}', SOURCE_PORT={int(port)}, SOURCE_USER='{sql_user}', SOURCE_PASSWORD='{sql_pw}', SOURCE_LOG_FILE='$file', SOURCE_LOG_POS=$pos, GET_SOURCE_PUBLIC_KEY=1; START REPLICA;"
ready=0
st=''
for _ in $(seq 1 60); do
  st=$(root mysql --protocol=tcp -h 127.0.0.1 -uroot -e 'SHOW REPLICA STATUS\\G' || true)
  if printf '%s{nl}' "$st" | grep -Eq 'Replica_IO_Running: Yes|Slave_IO_Running: Yes' \
    && printf '%s{nl}' "$st" | grep -Eq 'Replica_SQL_Running: Yes|Slave_SQL_Running: Yes'; then
    ready=1
    break
  fi
  sleep 2
done
if [ "$ready" != 1 ]; then
  echo '[awsbox] replica did not start' >&2
  printf '%s{nl}' "$st" >&2
  exit 1
fi
root mysql --protocol=tcp -h 127.0.0.1 -uroot -e 'SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;'
echo '[awsbox] mysql reader is super_read_only'
wait "$pid"
"""


def _stamp_cluster(context, cluster: dict) -> None:
    from localemu.services.rds.provider import _init_db_manager, _rds_endpoint_address

    cid = cluster.get("DBClusterIdentifier")
    mgr = _init_db_manager()
    if not mgr or not cid:
        return
    info = mgr.get_instance_info(cid)
    host_port = getattr(info, "host_port", None) if info is not None else None
    if not host_port:
        return
    region = context.region or "us-east-1"
    cluster["Endpoint"] = _rds_endpoint_address(cid, region)
    cluster["Port"] = host_port
    cluster["ReaderEndpoint"] = _rds_endpoint_address(f"{cid}-ro", region)
    cluster["Status"] = "available"


def _publish_managed_secret(context, resource: dict, username: str, password: str) -> None:
    from moto.secretsmanager import secretsmanager_backends

    secret_view = resource.get("MasterUserSecret")
    if not isinstance(secret_view, dict):
        LOG.warning("managed secret missing on RDS response")
        return
    arn = secret_view.get("SecretArn")
    if not isinstance(arn, str) or not arn:
        LOG.warning("managed secret arn missing")
        return
    account = context.account_id
    region = context.region or "us-east-1"
    backend = secretsmanager_backends[account][region]
    secret = None
    for key, val in backend.secrets.items():
        if key == arn or getattr(val, "arn", None) == arn:
            secret = val
            break
    if secret is None:
        LOG.warning(
            "managed secret %s not found (account=%s region=%s keys=%s)",
            arn, account, region, list(backend.secrets)[:6],
        )
        return
    payload = json.dumps({"username": username, "password": password})
    secret.secret_string = payload
    vid = secret.default_version_id
    if vid and vid in secret.versions:
        secret.versions[vid]["secret_string"] = payload
    else:
        for version in secret.versions.values():
            if "AWSCURRENT" in (version.get("version_stages") or []):
                version["secret_string"] = payload
                break
    secret_view["SecretStatus"] = "active"
    LOG.info("rds managed secret updated %s", arn)


def _require_mapped_engine(request) -> None:
    """Reject unknown EngineVersion before Moto/Docker (AWS InvalidParameterCombination)."""
    from localemu.aws.api import CommonServiceException
    from localemu.services.rds.docker.engine_mapping import (
        UnknownEngineVersionError,
        resolve_engine_image,
    )

    engine = _request_flag(request, "Engine")
    version = _request_flag(request, "EngineVersion")
    if not isinstance(engine, str) or not engine:
        return
    # Cluster members often omit EngineVersion; Docker inherits from the cluster.
    if version is None or version == "":
        return
    if not isinstance(version, str):
        return
    try:
        resolve_engine_image(engine, version)
    except UnknownEngineVersionError as exc:
        raise CommonServiceException(
            "InvalidParameterCombination",
            str(exc),
            status_code=400,
        ) from exc


def _install() -> None:
    from localemu.services.rds.docker import cluster_init
    from localemu.services.rds.docker.db_manager import DockerDbManager
    from localemu.services.rds import provider

    if getattr(cluster_init.is_postgres_engine, "_awsbox_mysql", False):
        return

    orig_is_pg = cluster_init.is_postgres_engine
    orig_writer = cluster_init.writer_postgres_command
    orig_reader = cluster_init.reader_container_command
    orig_apply = cluster_init.apply_writer_init
    orig_wait = cluster_init._wait_for_postgres_in_container
    orig_do = DockerDbManager._do_create_db_instance
    orig_wait_port = DockerDbManager._wait_for_port
    orig_create_cluster = provider._handle_create_db_cluster
    orig_create_instance = provider._handle_create_db_instance
    orig_dispatcher = provider.RdsDispatcher

    def is_postgres_engine(engine: str) -> bool:
        if _is_mysql(engine):
            return True
        return orig_is_pg(engine)

    def writer_postgres_command(max_readers: int = 16) -> list[str]:
        if _is_mysql(_ctx_engine()):
            return [
                "mysqld",
                "--server-id=1",
                "--log-bin=binlog",
                "--binlog-format=ROW",
                "--bind-address=0.0.0.0",
                "--default-authentication-plugin=mysql_native_password",
            ]
        return orig_writer(max_readers)

    def reader_container_command(
        writer_alias: str,
        port: int,
        repl_user: str,
        repl_password: str,
        max_readers: int = 16,
    ) -> list[str]:
        if _is_mysql(_ctx_engine()):
            ctx = _CTX.get() or {}
            instance_id = ctx.get("instance_id")
            sid = _server_id(instance_id if isinstance(instance_id, str) else "reader")
            return [
                "bash",
                "-c",
                _reader_shell(writer_alias, port, repl_user, repl_password, sid),
            ]
        return orig_reader(writer_alias, port, repl_user, repl_password, max_readers)

    def apply_writer_init(container_name, master_username, repl_user, repl_password):
        if _is_mysql(_ctx_engine()):
            _mysql_writer_init(container_name, repl_user, repl_password)
            return None
        return orig_apply(container_name, master_username, repl_user, repl_password)

    def _wait_for_postgres_in_container(container_name, master_username, timeout=60):
        if _is_mysql(_ctx_engine()):
            return _wait_mysql_reader(container_name, timeout)
        return orig_wait(container_name, master_username, timeout)

    def _wait_for_port(self, port, host="127.0.0.1", timeout=30):
        import socket as _socket

        # Published host ports are reachable via the container default
        # gateway, not via 127.0.0.1 inside LocalEmu.
        hosts = [host]
        gw = _default_gateway()
        if gw and gw not in hosts:
            hosts.append(gw)
        deadline = time.monotonic() + max(int(timeout), 90)
        while time.monotonic() < deadline:
            for candidate in hosts:
                try:
                    with _socket.create_connection((candidate, int(port)), timeout=1):
                        return True
                except OSError:
                    pass
            time.sleep(0.5)
        LOG.warning("Port %s did not become ready (tried %s)", port, hosts)
        return orig_wait_port(self, port, host, timeout=1)

    def _do_create(self, db_instance_id, engine, *args, **kwargs):
        token = _CTX.set(
            {
                "engine": (engine or "").lower(),
                "instance_id": db_instance_id,
                "is_writer": bool(kwargs.get("is_writer")),
            }
        )
        try:
            return orig_do(self, db_instance_id, engine, *args, **kwargs)
        finally:
            _CTX.reset(token)

    def _arm_managed_password(request) -> bool:
        managed = _truthy(_request_flag(request, "ManageMasterUserPassword"))
        if managed and not request.get("MasterUserPassword"):
            request["MasterUserPassword"] = _safe_password()
        if managed:
            LOG.info(
                "ManageMasterUserPassword=%r",
                _request_flag(request, "ManageMasterUserPassword"),
            )
        return managed

    def _handle_create_db_cluster(context, request):
        _require_mapped_engine(request)
        managed = _arm_managed_password(request)
        result = orig_create_cluster(context, request)
        cluster = (result or {}).get("DBCluster")
        if isinstance(cluster, dict):
            _stamp_cluster(context, cluster)
            if managed and request.get("MasterUserPassword"):
                username = cluster.get("MasterUsername") or request.get("MasterUsername") or "admin"
                _publish_managed_secret(
                    context,
                    cluster,
                    username if isinstance(username, str) else "admin",
                    request["MasterUserPassword"],
                )
        return result

    def _handle_create_db_instance(context, request):
        _require_mapped_engine(request)
        managed = _arm_managed_password(request)
        result = orig_create_instance(context, request)
        inst = (result or {}).get("DBInstance")
        if managed and isinstance(inst, dict) and request.get("MasterUserPassword"):
            username = inst.get("MasterUsername") or request.get("MasterUsername") or "admin"
            _publish_managed_secret(
                context,
                inst,
                username if isinstance(username, str) else "admin",
                request["MasterUserPassword"],
            )
        return result

    def _handle_describe_db_clusters(context, request):
        from localemu.services.moto import call_moto

        result = call_moto(context)
        for cluster in result.get("DBClusters") or []:
            if isinstance(cluster, dict):
                _stamp_cluster(context, cluster)
        return result

    def RdsDispatcher(service_model):
        table = orig_dispatcher(service_model)
        table["CreateDBCluster"] = _handle_create_db_cluster
        table["CreateDBInstance"] = _handle_create_db_instance
        table["DescribeDBClusters"] = _handle_describe_db_clusters
        return table

    setattr(is_postgres_engine, "_awsbox_mysql", True)
    cluster_init.is_postgres_engine = is_postgres_engine
    cluster_init.writer_postgres_command = writer_postgres_command
    cluster_init.reader_container_command = reader_container_command
    cluster_init.apply_writer_init = apply_writer_init
    cluster_init._wait_for_postgres_in_container = _wait_for_postgres_in_container
    DockerDbManager._do_create_db_instance = _do_create
    DockerDbManager._wait_for_port = _wait_for_port
    provider._handle_create_db_cluster = _handle_create_db_cluster
    provider._handle_create_db_instance = _handle_create_db_instance
    provider._INTERCEPTED_OPS["CreateDBCluster"] = _handle_create_db_cluster
    provider._INTERCEPTED_OPS["CreateDBInstance"] = _handle_create_db_instance
    provider._INTERCEPTED_OPS["DescribeDBClusters"] = _handle_describe_db_clusters
    provider.RdsDispatcher = RdsDispatcher
    LOG.info("awsbox rds mysql patch applied")


_install()
