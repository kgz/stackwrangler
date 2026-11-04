# Transfer Family SFTP → S3

Inbound SFTP lands objects in S3. Native SSH key path is smoked; LOGICAL / IdP / deeper authz still open.

**Status:** partial · Gaps: console user/key [#321](https://github.com/kgz/stackwrangler/issues/321) · LOGICAL/IdP [#322](https://github.com/kgz/stackwrangler/issues/322)

## Sequence

1. Create Transfer server + user mapped to an S3 bucket.
2. SFTP put with SSH key (or dataplane sidecar path).
3. Object appears in the home bucket.
4. Sad: wrong key denied.

## Prove it

```bash
./smokes/transfer/transfer-key-smoke.sh
./smokes/transfer/transfer-dataplane-smoke.sh
```
