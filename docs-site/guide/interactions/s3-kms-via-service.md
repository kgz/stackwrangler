# S3 SSE-KMS → ViaService / SourceArn

PutObject/GetObject with a customer CMK evaluates the caller’s `kms:GenerateDataKey` / `kms:Decrypt` with service-origin `kms:ViaService=s3.<region>.amazonaws.com`, `aws:SourceArn` (bucket), and `aws:SourceAccount` — not client headers. Direct `kms:Decrypt` without ViaService is denied when the identity Allow requires it. EC2 `IamInstanceProfile` is PassRole with `iam:PassedToService=ec2.amazonaws.com`.

**Status:** shipped

## Sequence

1. Identity Allow for KMS crypto conditioned on `kms:ViaService`.
2. Put/Get SSE-KMS on LocalEmu S3 (`:4566`) succeeds; direct Decrypt fails.
3. Key policy `aws:SourceArn` / `aws:SourceAccount` match vs mismatch.
4. RunInstances with instance profile Allowed; same role to EventBridge Denied.

## Prove it

```bash
./smokes/security/service-origin-condition-keys-smoke.sh
```
