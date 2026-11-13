"""RDS engine to Docker image mapping (pinned tags).

Replaces LocalEmu's floating-tag fallbacks: every mapped version resolves
to an exact image tag, and unknown versions raise instead of drifting to
``mysql:8.0`` / ``postgres:16``.
"""

from __future__ import annotations

import logging
import re

LOG = logging.getLogger(__name__)

_AURORA_MYSQL_FULL = re.compile(
    r"^(?P<community>\d+\.\d+)\.mysql_aurora\.(?P<aurora>\d+\.\d+\.\d+)$",
    re.IGNORECASE,
)
_AURORA_PG_FULL = re.compile(
    r"^(?P<community>\d+)\.postgresql_aurora\.(?P<aurora>\d+\.\d+)$",
    re.IGNORECASE,
)

# Aurora MySQL 3.x → community MySQL patch it is based on (AWS release notes).
_AURORA_MYSQL_BASE: dict[str, str] = {
    "3.01.0": "8.0.23",
    "3.01.1": "8.0.23",
    "3.02.0": "8.0.23",
    "3.02.1": "8.0.23",
    "3.02.2": "8.0.23",
    "3.02.3": "8.0.23",
    "3.03.0": "8.0.26",
    "3.03.1": "8.0.26",
    "3.03.2": "8.0.26",
    "3.03.3": "8.0.26",
    "3.04.0": "8.0.28",
    "3.04.1": "8.0.28",
    "3.04.2": "8.0.28",
    "3.04.3": "8.0.28",
    "3.05.0": "8.0.32",
    "3.05.0.1": "8.0.32",
    "3.05.1": "8.0.32",
    "3.05.2": "8.0.32",
    "3.06.0": "8.0.34",
    "3.06.1": "8.0.34",
    "3.07.0": "8.0.36",
    "3.07.1": "8.0.36",
    "3.08.0": "8.0.39",
    "3.08.1": "8.0.39",
    "3.08.2": "8.0.39",
}


def _mysql_tag(ver: str) -> str:
    return f"mysql:{ver}"


def _aurora_mysql_entries() -> dict[str, str]:
    out: dict[str, str] = {}
    for aurora_ver, mysql_ver in _AURORA_MYSQL_BASE.items():
        tag = _mysql_tag(mysql_ver)
        out[aurora_ver] = tag
        out[f"8.0.mysql_aurora.{aurora_ver}"] = tag
        # major.minor series alias (3.05 → same pin as latest listed patch)
        major_minor = ".".join(aurora_ver.split(".")[:2])
        out.setdefault(major_minor, tag)
    # family shorthand used by some clients
    out["3"] = _mysql_tag("8.0.39")
    out["8.0"] = _mysql_tag("8.0.39")
    out["default"] = _mysql_tag("8.0.39")
    return out


ENGINE_IMAGE_MAP: dict[str, dict[str, str]] = {
    "mysql": {
        "8.4": "mysql:8.4.3",
        "8.4.3": "mysql:8.4.3",
        "8.4.2": "mysql:8.4.2",
        "8.0": "mysql:8.0.39",
        "8.0.39": "mysql:8.0.39",
        "8.0.37": "mysql:8.0.37",
        "8.0.36": "mysql:8.0.36",
        "8.0.35": "mysql:8.0.35",
        "8.0.34": "mysql:8.0.34",
        "8.0.33": "mysql:8.0.33",
        "8.0.32": "mysql:8.0.32",
        "8.0.28": "mysql:8.0.28",
        "8.0.26": "mysql:8.0.26",
        "8.0.23": "mysql:8.0.23",
        "5.7": "mysql:5.7.44",
        "5.7.44": "mysql:5.7.44",
        "default": "mysql:8.0.39",
    },
    "postgres": {
        "17": "postgres:17.2",
        "17.2": "postgres:17.2",
        "17.1": "postgres:17.1",
        "16": "postgres:16.6",
        "16.6": "postgres:16.6",
        "16.4": "postgres:16.4",
        "16.3": "postgres:16.3",
        "15": "postgres:15.10",
        "15.10": "postgres:15.10",
        "15.8": "postgres:15.8",
        "14": "postgres:14.15",
        "14.15": "postgres:14.15",
        "14.13": "postgres:14.13",
        "13": "postgres:13.18",
        "13.18": "postgres:13.18",
        "13.16": "postgres:13.16",
        "default": "postgres:16.6",
    },
    "mariadb": {
        "11.4": "mariadb:11.4.4",
        "11.4.4": "mariadb:11.4.4",
        "11.4.3": "mariadb:11.4.3",
        "10.11": "mariadb:10.11.10",
        "10.11.10": "mariadb:10.11.10",
        "10.11.9": "mariadb:10.11.9",
        "10.6": "mariadb:10.6.21",
        "10.6.21": "mariadb:10.6.21",
        "10.6.19": "mariadb:10.6.19",
        "default": "mariadb:11.4.4",
    },
    "aurora-mysql": _aurora_mysql_entries(),
    "aurora-postgresql": {
        "16.4": "postgres:16.4",
        "16.1": "postgres:16.1",
        "16": "postgres:16.6",
        "15.8": "postgres:15.8",
        "15.4": "postgres:15.4",
        "15": "postgres:15.10",
        "14.13": "postgres:14.13",
        "14": "postgres:14.15",
        "default": "postgres:16.6",
    },
}

SUPPORTED_ENGINES = set(ENGINE_IMAGE_MAP.keys())

ENGINE_DEFAULT_PORT: dict[str, int] = {
    "mysql": 3306,
    "postgres": 5432,
    "mariadb": 3306,
    "aurora-mysql": 3306,
    "aurora-postgresql": 5432,
}

ENGINE_ENV_VARS: dict[str, dict[str, str]] = {
    "mysql": {
        "user_env": "MYSQL_USER",
        "password_env": "MYSQL_PASSWORD",
        "database_env": "MYSQL_DATABASE",
        "root_password_env": "MYSQL_ROOT_PASSWORD",
    },
    "postgres": {
        "user_env": "POSTGRES_USER",
        "password_env": "POSTGRES_PASSWORD",
        "database_env": "POSTGRES_DB",
    },
    "mariadb": {
        "user_env": "MARIADB_USER",
        "password_env": "MARIADB_PASSWORD",
        "database_env": "MARIADB_DATABASE",
        "root_password_env": "MARIADB_ROOT_PASSWORD",
    },
}


class UnknownEngineVersionError(ValueError):
    """Raised when EngineVersion is not in the pinned map."""

    def __init__(self, engine: str, engine_version: str) -> None:
        self.engine = engine
        self.engine_version = engine_version
        super().__init__(
            f"Cannot find version {engine_version} for {engine}"
        )


def normalize_engine_version(engine: str, engine_version: str) -> str:
    """Normalize AWS-style Aurora version strings to map keys."""
    engine_lower = engine.lower()
    ver = engine_version.strip()
    if engine_lower == "aurora-mysql":
        m = _AURORA_MYSQL_FULL.match(ver)
        if m:
            return m.group("aurora")
        return ver
    if engine_lower == "aurora-postgresql":
        m = _AURORA_PG_FULL.match(ver)
        if m:
            return m.group("aurora")
        return ver
    return ver


def _is_floating_tag(image: str) -> bool:
    """True for tags like mysql:8.0 / postgres:16 (no patch pin)."""
    if ":" not in image:
        return True
    _name, tag = image.rsplit(":", 1)
    if tag in ("latest", "8.0", "5.7", "8.4"):
        return True
    parts = tag.split(".")
    # postgres major-only (16) is floating; 16.6 is pinned
    if len(parts) == 1 and parts[0].isdigit():
        return True
    return False


def resolve_engine_image(engine: str, engine_version: str | None = None) -> str:
    """Resolve an RDS engine name and version to a pinned Docker image.

    Raises:
        UnknownEngineVersionError: when a version is given but not mapped.
    """
    engine_lower = (engine or "").lower()
    versions = ENGINE_IMAGE_MAP.get(engine_lower)

    if not versions:
        LOG.warning(
            "Unsupported RDS engine '%s' — not in %s. "
            "Falling back to postgres:16.6. Behavior may differ from AWS.",
            engine,
            sorted(SUPPORTED_ENGINES),
        )
        return "postgres:16.6"

    if not engine_version:
        image = versions["default"]
        if _is_floating_tag(image):
            raise UnknownEngineVersionError(engine_lower, "default")
        return image

    raw = engine_version.strip()
    # Exact raw key first (full Aurora form or community version)
    if raw in versions:
        return versions[raw]

    normalized = normalize_engine_version(engine_lower, raw)
    if normalized in versions:
        return versions[normalized]

    raise UnknownEngineVersionError(engine_lower, raw)


def get_engine_port(engine: str) -> int:
    """Get the default port for an engine."""
    return ENGINE_DEFAULT_PORT.get(engine.lower(), 5432)


def get_engine_env_vars(
    engine: str,
    master_username: str,
    master_password: str,
    db_name: str | None = None,
) -> dict[str, str]:
    """Build environment variables for the database container."""
    engine_lower = engine.lower()
    if engine_lower.startswith("aurora-mysql"):
        engine_lower = "mysql"
    elif engine_lower.startswith("aurora-postgresql"):
        engine_lower = "postgres"

    env_config = ENGINE_ENV_VARS.get(engine_lower, ENGINE_ENV_VARS["postgres"])
    env: dict[str, str] = {}

    if engine_lower == "postgres":
        env[env_config["user_env"]] = master_username
        env[env_config["password_env"]] = master_password
        if db_name:
            env[env_config["database_env"]] = db_name
    elif engine_lower in ("mysql", "mariadb"):
        env[env_config["root_password_env"]] = master_password
        if not db_name:
            db_name = "main"
        env[env_config["database_env"]] = db_name
        if master_username != "root":
            env[env_config["user_env"]] = master_username
            env[env_config["password_env"]] = master_password

    return env
