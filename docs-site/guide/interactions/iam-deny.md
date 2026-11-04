# IAM AccessDenied lab

Create a user that is denied `s3:ListAllMyBuckets` (or equivalent). Call with that principal → AccessDenied. Console IAM lab aligns with the smoke.

**Status:** shipped

## Sequence

1. Create user + deny policy.
2. Call with that user’s keys against LocalEmu.
3. Expect AccessDenied (not a silent allow).

## Prove it

```bash
./smokes/security/iam-access-denied.sh
```
