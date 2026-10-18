# AWS Transfer Family (local)

LocalEmu `transfer` service on `:4566`. Profile `local` routes `transfer` there.

## What works

```bash
./bin/awsbox up --force
./bin/transfer-smoke.sh
aws --profile local transfer list-servers
```

- `create-server` / `delete-server` (SFTP, `SERVICE_MANAGED`)
- `create-user` / `describe-user` / `delete-user` with IAM role + S3 home (`PATH`)
- Home bucket on **LocalEmu S3** (`:4566`), not SeaweedFS — same dual-S3 rule as Lambda/IaC

## Limits (honest)

| Area | Local behaviour |
|------|-----------------|
| SFTP data plane | Likely stubbed — do not expect a real SSH/SFTP listen for file put/get |
| SSH public keys | API accepts users without keys; real AWS needs `ImportSshPublicKey` |
| `list-servers` / `list-users` | May return empty after create; use `describe-server` / `describe-user` |
| FTPS/FTP | Not exercised; enable only if you need API apply for those protocols |
| VPC endpoint / EIP | Not required for API smoke; org VPC wiring is a later learning path (#91) |

## Org path

Full hop `VPC → Transfer → Lambda → S3 → ECS → RDS` is epic [#90](https://github.com/kgz/awsl/issues/90) / path [#91](https://github.com/kgz/awsl/issues/91). This ticket is the Transfer API foundation.
