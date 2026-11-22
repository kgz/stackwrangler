# Transfer Family SFTP → S3

Inbound SFTP lands objects in S3 under the user's Transfer role (SSH public keys). Empty-role put is denied; LOGICAL homes and custom IdPs are not supported.

**Status:** partial · Gaps: console user/key [#321](https://github.com/kgz/stackwrangler/issues/321) · Full org chain [use case](../use-cases/org-path) ([#781](https://github.com/kgz/stackwrangler/issues/781)) · [docs/transfer.md](../../../docs/transfer.md)

## Sequence

1. Create Transfer server + user mapped to an S3 bucket (PATH home).
2. SFTP put with SSH key (or dataplane sidecar path).
3. Object appears in the home bucket.
4. Sad: wrong key denied; Transfer role without `s3:PutObject` → Permission denied and no object.
5. N/A: LOGICAL `HomeDirectoryMappings` refuse login; `API_GATEWAY` / Directory / Lambda IdP never invoked.

## Prove it

```bash
./smokes/transfer/transfer-key-smoke.sh
./smokes/transfer/transfer-dataplane-smoke.sh
./smokes/transfer/transfer-authz-smoke.sh
```
