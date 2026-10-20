## Context

Prowler 5.x against `AWS_ENDPOINT_URL=http://127.0.0.1:4566` completes, but ~19 distinct API calls fail. Worst: S3 Control uses `http://<account-id>.127.0.0.1:4566/...`, which does not resolve. Several services Prowler probes are not in `SERVICES`. LocalEmu's `S3ControlProvider` only implements tagging; moto already has public-access / access-point list methods.

## Goals / Non-Goals

**Goals:** Isolated prowler smoke with failing-call ratchet; S3 Control reachable + three list/get calls succeed; empty read responses for listed services; docs.

**Non-Goals:** Zero Prowler findings; forking LocalEmu as a permanent product; #193–#195.

## Decisions

1. **Isolated AWS config via `env -i`** — smoke writes a temp `AWS_CONFIG_FILE` / credentials with only awsbox keys and the LocalEmu endpoint. No host profile, no real-account fallthrough.
2. **Endpoint host that supports account-id DNS** — use `http://localhost.localstack.cloud:4566` (wildcard `*.localhost.localstack.cloud` → 127.0.0.1) for the Prowler smoke so boto3's `<account-id>.<host>` form resolves. Keep CLI profile `local` on `127.0.0.1` unless we prove a reason to change it globally.
3. **Enable services in compose** — add to `SERVICES`: `ssm,cloudwatch,cloudtrail,organizations,backup,batch,applicationautoscaling` (and `dax` if LocalEmu exposes it). Empty account = valid empty Describe/List responses.
4. **S3 Control + missing actions via mount patch** — ship `localemu-patches/prowler_compat.py` (or similar) mounted into the LocalEmu container and loaded at startup (extension / PYTHONPATH / init hook — pick whatever LocalEmu already supports; prefer plux extension if available). Wire moto backends for `GetPublicAccessBlock`, `ListAccessPoints`, `ListMultiRegionAccessPoints`; stub EC2/IAM/RDS gaps with AWS-shaped empty/default responses.
5. **Baseline file** — `testdata/prowler/failing-api-baseline.txt` (or count + sorted list). Smoke fails if distinct failing API count **increases**; ratchet down by editing the file when gaps close.

## Risks / Trade-offs

- [LocalEmu `latest` drifts] → smoke + baseline make regressions visible; pin notes in docs if needed.
- [Patch coupling to LocalEmu internals] → keep patch small; document upstream follow-up.
- [DAX / Batch may be absent in image] → enable what exists; remaining failures stay in baseline.
