# AWS Transfer Family (local)

LocalEmu `transfer` on `:4566` = **control plane** (create-server / create-user / ImportSshPublicKey).  
**Inbound SFTP** = native listener inside LocalEmu (`start.d/20-transfer-sftp.py`) on `127.0.0.1:${AWSBOX_SFTP_HOST_PORT:-2222}` — **SSH public keys only** (no `awsboxpass`).

Optional `legacy-sftp` compose profile (atmoz password target on `:2223`) remains for outbound connector probes that need a dumb remote host.

## Smokes

```bash
./bin/awsbox up --force
./bin/transfer-smoke.sh              # API: server + user + S3 home
./bin/transfer-key-smoke.sh          # SSH key auth + put → S3 + ObjectCreated Lambda
./bin/transfer-dataplane-smoke.sh    # short key put → S3 (no Lambda)
./bin/transfer-authz-smoke.sh        # empty Transfer role → PutObject deny (simulate)
```

## Architecture (honest)

| Layer | Implementation |
|-------|----------------|
| IaC / API | LocalEmu Transfer (`--profile local transfer …`) |
| Bytes in | Native SFTP in LocalEmu (`AWSBOX_TRANSFER_SFTP_PORT`, published as `AWSBOX_SFTP_HOST_PORT`) |
| Auth | SERVICE_MANAGED users + `ImportSshPublicKey` (password rejected) |
| Bytes → S3 | Put/Get under the user's Transfer role via gateway AssumeRole |

`DescribeServer` includes `Endpoint` = `127.0.0.1:<host-port>` and reports `ONLINE`.

## Limits

| Area | Behaviour |
|------|-----------|
| `list-servers` / `list-users` | May be empty; use `describe-*` |
| FTPS/FTP / AS2 | Not exercised |
| Home type | PATH `/bucket` or `/bucket/prefix` only (LOGICAL / IdP → [#322](https://github.com/kgz/awsl/issues/322)) |
| Authz under Transfer role | API simulate: `transfer-authz-smoke.sh`; deeper SFTP-byte deny matrix → [#322](https://github.com/kgz/awsl/issues/322) |
| Console create user / import key | CLI / smoke only → [#321](https://github.com/kgz/awsl/issues/321) |
| IdP / custom identity providers | Not implemented → [#322](https://github.com/kgz/awsl/issues/322) |
| Host key | Ephemeral RSA in the LocalEmu container (`StrictHostKeyChecking=no` in smokes) |

## Slice

Replication slice: [`examples/serverless-v3-rest/slices/transfer-in/`](../examples/serverless-v3-rest/slices/transfer-in/) (`AWS::Transfer::Server` shape + S3 event Lambda). Smoke: `./bin/transfer-key-smoke.sh`.
