# Secrets Manager → KMS ViaService / ResourceAliases

`GetSecretValue` on a secret encrypted with a customer CMK evaluates the caller’s `kms:Decrypt` with service-origin `kms:ViaService=secretsmanager.<region>.amazonaws.com`, `aws:SourceAccount`, optional `aws:SourceArn` (secret), and multi-valued `kms:ResourceAliases` (aliases on the key). The secret’s stored `KmsKeyId` alias resolves to the UUID key ARN before authz — not `key/alias/...`. Direct `kms:Decrypt` without ViaService is denied when the identity Allow requires it; a mismatched alias is denied.

**Status:** shipped

## Sequence

1. Create CMK + `alias/…`; create secret with `--kms-key-id alias/…`.
2. Identity Allow for `kms:Decrypt` conditioned on `kms:ViaService` + `ForAnyValue:StringEquals` / `kms:ResourceAliases`.
3. `GetSecretValue` succeeds; direct Decrypt and wrong-alias policy fail.

## Prove it

```bash
./smokes/security/kms-via-secrets-aliases-smoke.sh
```
