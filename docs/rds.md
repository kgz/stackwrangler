# RDS (local)

LocalEmu `rds` with **`RDS_DOCKER_BACKEND=1`** starts a real Postgres/MySQL container via Docker.

```bash
./bin/awsbox up --force
./bin/rds-smoke.sh
```

Keep instance: `AWSBOX_RDS_KEEP=1 ./bin/rds-smoke.sh`

## What works

- `create-db-instance` / `describe-db-instances` / `delete-db-instance`
- Endpoint becomes `localhost:<ephemeral-port>` when Docker backend is on
- SQL via `psql` (smoke does CREATE/INSERT/SELECT)

## Limits

| Area | Behaviour |
|------|-----------|
| Without `RDS_DOCKER_BACKEND` | Moto-only fake hostname — no SQL |
| Aurora failover / replicas | Partial in LocalEmu — document if you rely on it |
| Security groups / VPC | Enforced on the VPC address when a DB subnet group is set ([docs/sg-enforcement.md](sg-enforcement.md)); published host port is separate |
| Console create | Not wired — debt [#145](https://github.com/kgz/awsl/issues/145) |

Needs `psql` on the host for the smoke.
