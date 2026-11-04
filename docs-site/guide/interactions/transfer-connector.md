# Transfer connector: S3 → remote SFTP

Outbound connector (`StartFileTransfer`) pushes from S3 to a remote SFTP. Lambda may create the tenant connector. Authz: missing `s3:GetObject` / secret / `kms:Decrypt`, trust scoped wrong, PassRole deny.

**Status:** partial · Gaps: console connectors [#313](https://github.com/kgz/stackwrangler/issues/313) · retrieve/AS2 [#314](https://github.com/kgz/stackwrangler/issues/314)

## Sequence

1. Provision connector + credentials secret.
2. `start-file-transfer`; watch success / CloudWatch-shaped events the smoke asserts.
3. Sad: permission holes; wrong host key.

## Prove it

```bash
./smokes/transfer/transfer-connector-smoke.sh
```
