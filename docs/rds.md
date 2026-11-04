# RDS (local)

LocalEmu `rds` with **`RDS_DOCKER_BACKEND=1`** starts a real Postgres or MySQL container via Docker.

```bash
./bin/stackwrangler up --force
./bin/rds-smoke.sh          # Postgres
./bin/rds-mysql-smoke.sh    # MySQL instance + Aurora MySQL cluster
```

Keep resources: `AWSBOX_RDS_KEEP=1 ./bin/rds-mysql-smoke.sh`

Needs host `psql` (Postgres smoke) or `mysql` (MySQL smoke).

## What works

- `create-db-instance` / `describe-db-instances` / `delete-db-instance` for `postgres` and `mysql`
- `create-db-cluster` for `aurora-mysql`: writer container, cluster endpoint on `localhost:<host-port>`
- Further `create-db-instance --db-cluster-identifier` adds a **reader**. Its endpoint is the instance host port (read-only). The cluster `ReaderEndpoint` hostname is the same style as the writer (`localhost`); the published port is on the reader instance
- `ManageMasterUserPassword` stores `{"username","password"}` in Secrets Manager (`rds!…`). The container uses that password
- SQL via `psql` or `mysql`

Aurora MySQL binlog setup lives in `localemu-patches/init/start.d/20-rds-mysql.py` (mounted with the other init scripts). `SERVICES` already includes `rds` and `secretsmanager`.

## Limits

| Area | Behaviour |
|------|-----------|
| Without `RDS_DOCKER_BACKEND` | Moto-only fake hostname — no SQL |
| Cluster writer | `CreateDBCluster` starts the writer. The first extra instance is a reader |
| Reader port | Host port is on the reader DB instance, not a second cluster port field |
| Aurora MySQL failover | Postgres `pg_ctl` path only — [#225](https://github.com/kgz/awsl/issues/225) |
| Managed secret rotation | Create/get only |
| Security groups / VPC | Enforced on the VPC address when a DB subnet group is set ([docs/sg-enforcement.md](sg-enforcement.md)); published host port is separate |
| Private DNS from workloads | [#206](https://github.com/kgz/awsl/issues/206) |
| Console create | Not wired — [#145](https://github.com/kgz/awsl/issues/145) |
