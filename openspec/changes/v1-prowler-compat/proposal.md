## Why

Prowler is the standard open-source AWS posture scanner. Running it against awsl lets a local stack get a security check before real AWS. Today S3 Control hostnames don't resolve, several read-only services aren't enabled, and a few APIs are missing — so checks are skipped or fail noisily.

## What Changes

- `bin/prowler-smoke.sh`: isolated Prowler run (`env -i`, dummy keys + local endpoint only), `--log-level ERROR`, report distinct failing API calls; fail if count rises above a checked-in baseline (ratchet)
- Endpoint / DNS so S3 Control `<account-id>.<host>` reaches LocalEmu; implement or expose `GetPublicAccessBlock`, `ListAccessPoints`, `ListMultiRegionAccessPoints` so S3 public-access checks produce results
- Enable read-only empty services Prowler hits: SSM, CloudWatch, CloudTrail, Organizations, Backup, Batch, Application Auto Scaling, DAX (as available in LocalEmu)
- Stub/complete missing actions where LocalEmu already has the service: EC2 / IAM / RDS gaps listed in #196
- Docs: `docs/prowler.md` (isolation setup); README status row

## Non-goals

- Fixing every Prowler finding (posture of the empty lab account)
- Resource policies (#193), call log (#194), least-privilege report (#195)
- Shipping a forked LocalEmu image long-term (prefer compose + thin patches / upstream)

## Capabilities

### New Capabilities

- `prowler-compat`: isolated Prowler smoke, S3 Control reachability, empty read APIs, failing-call baseline ratchet

### Modified Capabilities

(none)

## Impact

- `docker-compose.yml`, `bin/awsbox-profile`, `bin/prowler-smoke.sh`, baseline file, docs, README
- May add a small LocalEmu mount/patch for S3 Control + missing actions
- Issue: #196
