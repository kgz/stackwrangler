# AWS Transfer Family (local)

LocalEmu `transfer` on `:4566` = **control plane** (create-server / create-user).  
Real SFTP listen = **awsbox `sftp` sidecar** on `127.0.0.1:2222` (atmoz/sftp).

## Smokes

```bash
./bin/awsbox up --force
./bin/transfer-smoke.sh              # API: server + user + S3 home
./bin/transfer-dataplane-smoke.sh    # SFTP put → LocalEmu S3 (bridge)
```

Credentials (sidecar): user `awsbox` / pass `awsboxpass` (override via `AWSBOX_SFTP_*`).

## Architecture (honest)

| Layer | Implementation |
|-------|----------------|
| IaC / API | LocalEmu Transfer (`--profile local transfer …`) |
| Bytes in | `sftp` compose service `:2222` |
| Bytes → S3 | Smoke/bridge copies inbox → LocalEmu S3 (`:4566`) |

LocalEmu does **not** currently speak SSH/SFTP for Transfer. awsbox bridges so org paths can still move a file into S3 locally.

**Tracked debt:** native Transfer auth (SSH keys) + drop sidecar password — [#141](https://github.com/kgz/awsl/issues/141).

## Limits

| Area | Behaviour |
|------|-----------|
| `list-servers` / `list-users` | May be empty; use `describe-*` |
| FTPS/FTP | Not exercised |
| Authz under Transfer role | API-shaped; deepen with workload IAM smokes later |
