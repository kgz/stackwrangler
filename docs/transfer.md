# AWS Transfer Family (local)

LocalEmu `transfer` on `:4566` = **control plane** (create-server / create-user / ImportSshPublicKey).  
**Inbound SFTP** = native listener inside LocalEmu (`start.d/20-transfer-sftp.py`) on `127.0.0.1:${AWSBOX_SFTP_HOST_PORT:-2222}` — **SSH public keys only** (no `awsboxpass`).

Optional `legacy-sftp` compose profile (atmoz password target on `:2223`) remains for outbound connector probes that need a dumb remote host.

## Upgrading from `beta/full-flow-v1`

That branch published atmoz SFTP as compose service `sftp` on `127.0.0.1:${AWSBOX_SFTP_HOST_PORT:-2222}` (container `awsl-sftp-1`). This tree runs inbound SFTP inside the emulator on the same host port. The password target is the `legacy-sftp` profile on `127.0.0.1:${AWSBOX_LEGACY_SFTP_HOST_PORT:-2223}`.

`./bin/stackwrangler up` removes this checkout's leftover `sftp` container when it still holds the emulator port: compose project label matches this directory, service `sftp`, image `atmoz/sftp`. Another project's SFTP server, or anything else on the port, makes `up` exit before Compose and names the holder. A failed bind otherwise leaves the emulator container `Created` and the rest of the stack down.

```bash
docker rm -f awsl-sftp-1
# or keep the other process and move the emulator:
STACKWRANGLER_SFTP_HOST_PORT=2223 ./bin/stackwrangler up
```

Smoke: `./smokes/transfer/transfer-sftp-port-smoke.sh`.

**Outbound** (connectors that push S3 objects to a remote SFTP host) is a real data plane: see [Outbound SFTP connectors](#outbound-sftp-connectors).

## Smokes

```bash
./bin/stackwrangler up --force
./smokes/transfer/transfer-smoke.sh              # API: server + user + S3 home
./smokes/transfer/transfer-key-smoke.sh          # SSH key auth + put → S3 + ObjectCreated Lambda
./smokes/transfer/transfer-dataplane-smoke.sh    # short key put → S3 (no Lambda)
./smokes/transfer/transfer-authz-smoke.sh        # empty Transfer role → PutObject deny (simulate)
./smokes/transfer/transfer-connector-smoke.sh    # outbound connector: S3 object → remote SFTP host (+ sad paths)
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
| FTPS/FTP | Not exercised |
| Authz under Transfer role | `./smokes/transfer/transfer-authz-smoke.sh` (simulate); SFTP-byte deny → [#141](https://github.com/kgz/awsl/issues/141) |

## Outbound SFTP connectors

Per-tenant connector → access role → SFTP credentials in Secrets Manager → `StartFileTransfer`. Implemented in `localemu-patches/init/start.d/20-transfer-connectors.py` (moto has no connectors).

| API | Behaviour |
|-----|-----------|
| `create-connector` / `describe-connector` / `update-connector` / `delete-connector` / `list-connectors` | `Url` must be `sftp://host[:port]`. `SftpConfig.UserSecretId` + `TrustedHostKeys`. `AccessRole` / `LoggingRole` need `iam:PassRole` for non-root callers. |
| `test-connection` | Assumes the access role, reads the secret, opens an SFTP session. `Status` is `ERROR` until the host key is trusted; the key is returned in `SftpConnectionDetails.HostKey` (older AWS CLI models drop it — use `ssh-keyscan` or the SDK). |
| `start-file-transfer` | `--send-file-paths /bucket/key --remote-directory-path /dir`. Runs in the background and returns `TransferId`. |
| `list-file-transfer-results` | Per file `QUEUED` → `IN_PROGRESS` → `COMPLETED` / `FAILED` with `FailureCode` and `FailureMessage`. |

SFTP user secret (JSON): `{"Username": "...", "Password": "..."}` or `{"Username": "...", "PrivateKey": "-----BEGIN ..."}` (optional `Passphrase`).

### Access role

The role is **assumed through the gateway**, so its identity policy is enforced like any workload role:

- trust policy must allow `transfer.amazonaws.com` for the connector. Recommended scope:

  ```json
  {"Effect": "Allow", "Principal": {"Service": "transfer.amazonaws.com"}, "Action": "sts:AssumeRole",
   "Condition": {"StringEquals": {"aws:SourceAccount": "<account>"},
                 "ArnLike": {"aws:SourceArn": "arn:aws:transfer:<region>:<account>:connector/*"}}}
  ```

  A trust policy scoped to another account's connectors fails the transfer (`ACCESS_ROLE_TRUST`).
- `s3:GetObject` on the object (`ACCESS_DENIED_S3`)
- `secretsmanager:GetSecretValue` on the secret, plus `kms:Decrypt` when the secret uses a CMK (`ACCESS_DENIED_SECRET`)

`FailureCode` values are awsbox's (AWS does not publish a fixed list): `ACCESS_ROLE_TRUST`, `ACCESS_ROLE_NOT_FOUND`, `ACCESS_DENIED_S3`, `ACCESS_DENIED_SECRET`, `SECRET_*`, `HOST_KEY_NOT_TRUSTED`, `SFTP_AUTH_FAILED`, `CONNECTION_ERROR`, `SFTP_WRITE_FAILED`.

### Logging

With a `LoggingRole` (needs `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`), events go to `/aws/transfer/<connector-id>` (one stream per transfer): `TRANSFER_STARTED`, `SEND_FILE_COMPLETED`, `SEND_FILE_FAILED`, `TRANSFER_FAILED`.

### Smoke

`./smokes/transfer/transfer-connector-smoke.sh` runs the replication slice [`examples/serverless-v3-rest/slices/transfer-out/`](../examples/serverless-v3-rest/slices/transfer-out): a Lambda creates the tenant connector at runtime, trusts the host key, and sends an S3 object to the compose `sftp` container (`sftp://sftp:22`, user from `AWSBOX_SFTP_USER` / `AWSBOX_SFTP_PASS`).

Sad paths: access role without `s3:GetObject`, without the secret, without `kms:Decrypt`, trust scoped to another account, wrong host key, Lambda role without `iam:PassRole`.

### Limits

| Area | Behaviour |
|------|-----------|
| S3 source | LocalEmu S3 on `:4566` (not the SeaweedFS endpoint) — [#143](https://github.com/kgz/awsl/issues/143) |
| Retrieve / AS2 | `RetrieveFilePaths` and `As2Config` connectors are not supported |
| State | Connectors and transfer results live in LocalEmu memory (lost on restart) |
| SFTP client | `paramiko` is pip-installed into LocalEmu on boot (needs network) |
| Console | No connectors UI |
| Real AWS | `StartFileTransfer` is asynchronous there too; failure detail comes from results and logs |

Debt: console [#313](https://github.com/kgz/awsl/issues/313) · retrieve / AS2 [#314](https://github.com/kgz/awsl/issues/314) · offline SFTP client [#315](https://github.com/kgz/awsl/issues/315).
| FTPS/FTP / AS2 | Not exercised |
| Home type | PATH `/bucket` or `/bucket/prefix` only (LOGICAL / IdP → [#322](https://github.com/kgz/awsl/issues/322)) |
| Authz under Transfer role | API simulate: `transfer-authz-smoke.sh`; deeper SFTP-byte deny matrix → [#322](https://github.com/kgz/awsl/issues/322) |
| Console create user / import key | CLI / smoke only → [#321](https://github.com/kgz/awsl/issues/321) |
| IdP / custom identity providers | Not implemented → [#322](https://github.com/kgz/awsl/issues/322) |
| Host key | Ephemeral RSA in the LocalEmu container (`StrictHostKeyChecking=no` in smokes) |

## Slice

Replication slice: [`examples/serverless-v3-rest/slices/transfer-in/`](../examples/serverless-v3-rest/slices/transfer-in/) (`AWS::Transfer::Server` shape + S3 event Lambda). Smoke: `./smokes/transfer/transfer-key-smoke.sh`.
