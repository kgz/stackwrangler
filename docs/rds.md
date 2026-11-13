# RDS (local)

LocalEmu `rds` with **`RDS_DOCKER_BACKEND=1`** starts a real Postgres or MySQL container via Docker.

```bash
./bin/stackwrangler up --force
./smokes/data/rds-smoke.sh          # Postgres
./smokes/data/rds-mysql-smoke.sh    # MySQL instance + Aurora MySQL cluster
./smokes/data/rds-parameter-group-smoke.sh  # param group Source + TF converge
```

Keep resources: `STACKWRANGLER_RDS_KEEP=1 ./smokes/data/rds-mysql-smoke.sh`

Needs host `psql` (Postgres smoke) or `mysql` (MySQL smoke).

## What works

- `create-db-instance` / `describe-db-instances` / `delete-db-instance` for `postgres` and `mysql`
- **Stable host ports** ([#705](https://github.com/kgz/stackwrangler/issues/705)): `Endpoint.Port` is the published host port. Pass `--port 3306` (or tag `stackwrangler:host-port=3306`) to pin it when free; otherwise the first assigned port is kept for the life of the instance (reboot, LocalEmu restart, persistence recreate). A taken port returns `InvalidParameterValue` with a clear message. Console detail shows the same port from `describe-db-instances`. With `PERSISTENCE=1`, host port + master creds are also saved under the LocalEmu state dir so a volume recreate after `docker rm` keeps the same publish port. Prove restart + recreate with `./smokes/data/rds-host-port-restart-persist-smoke.sh`.
- `create-db-cluster` for `aurora-mysql`: writer container, cluster endpoint on `localhost:<host-port>` (cluster `--port` / tag pins the **writer** publish port)
- Further `create-db-instance --db-cluster-identifier` adds a **reader**. Readers get their **own** stable host port (pin with `--port` / tag on that instance). The cluster `ReaderEndpoint` hostname matches the writer style (`localhost`); clients that need the reader must use the **reader instance** `Endpoint.Address` + `Endpoint.Port` from `describe-db-instances` — there is no second port field on the cluster.
- `ManageMasterUserPassword` stores `{"username","password"}` in Secrets Manager (`rds!…`). The container uses that password
- SQL via `psql` or `mysql`

Aurora MySQL binlog setup lives in `localemu-patches/init/start.d/20-rds-mysql.py` (mounted with the other init scripts). `SERVICES` already includes `rds` and `secretsmanager`.

## Engine versions (pinned images)

`localemu-patches/rds_engine_mapping.py` maps every supported `Engine` / `EngineVersion` to an **exact** Docker tag. Unknown versions raise `InvalidParameterCombination` (`Cannot find version …`) — they never silently fall back to floating tags like `mysql:8.0`.

| Engine | Example `EngineVersion` | Docker image |
|--------|-------------------------|--------------|
| `mysql` | `8.0.37` | `mysql:8.0.37` |
| `mysql` | `8.0` (series) | `mysql:8.0.39` |
| `postgres` | `16.3` | `postgres:16.3` |
| `postgres` | `16` (series) | `postgres:16.6` |
| `mariadb` | `11.4.4` | `mariadb:11.4.4` |
| `aurora-mysql` | `8.0.mysql_aurora.3.05.2` or `3.05.2` | `mysql:8.0.32` |
| `aurora-mysql` | `8.0.mysql_aurora.3.07.1` | `mysql:8.0.36` |
| `aurora-mysql` | `8.0.mysql_aurora.3.08.0` | `mysql:8.0.39` |
| `aurora-postgresql` | `16.4` | `postgres:16.4` |

Aurora MySQL 3.x pins follow AWS community compatibility (3.05 → 8.0.32, 3.06 → 8.0.34, 3.07 → 8.0.36, 3.08 → 8.0.39). Defaults are pinned too (`mysql` → `mysql:8.0.39`, `postgres` → `postgres:16.6`).

Keep the map current: `./bin/check-rds-engine-map.sh` compares it to `testdata/rds/describe-db-engine-versions.json`. Smoke: `./smokes/data/rds-engine-version-smoke.sh`.

## Limits

| Area | Behaviour |
|------|-----------|
| Without `RDS_DOCKER_BACKEND` | Moto-only fake hostname — no SQL |
| Cluster writer | `CreateDBCluster` starts the writer. The first extra instance is a reader |
| Reader port | Host port is on the reader DB instance (`describe-db-instances`), not a second cluster port field |
| Host port pin | `--port` / `stackwrangler:host-port` = published host port; engine listen port stays the image default |
| Aurora MySQL failover | Postgres `pg_ctl` path only — [#225](https://github.com/kgz/awsl/issues/225) |
| Managed secret rotation | Create/get only |
| Security groups / VPC | Enforced on the VPC address when a DB subnet group is set ([docs/sg-enforcement.md](sg-enforcement.md)); published host port is separate |
| Private DNS from workloads | [#206](https://github.com/kgz/awsl/issues/206) |
| Console create | Wired for Postgres/MySQL `CreateDBInstance` (`/rds/create`). Aurora engine choice disabled — use `./smokes/data/rds-mysql-smoke.sh` |
| Parameter groups (API / Terraform) | `DescribeDBParameters` / cluster variant return `Source=user` for modified params so `aws_db_parameter_group` converges ([#710](https://github.com/kgz/stackwrangler/issues/710)). Applying those settings into the Docker DB is [#703](https://github.com/kgz/stackwrangler/issues/703) |

## Aurora scope

Aurora **MySQL** is exercised by `./smokes/data/rds-mysql-smoke.sh` (`create-db-cluster` + reader instance + managed secret). Console **Create database** does not create Aurora clusters — the Aurora engine tile is disabled with `title="To implement"`. Aurora PostgreSQL / failover beyond the MySQL smoke remains [#225](https://github.com/kgz/awsl/issues/225).

Interactions: [rds-create-sql](../docs-site/guide/interactions/rds-create-sql.md) · shot `docs/assets/console/rds-databases.png`.
