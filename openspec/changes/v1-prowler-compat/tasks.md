## 1. Stack (#196)

- [x] 1.1 Add Prowler-needed services to LocalEmu `SERVICES` (ssm, cloudwatch, cloudtrail, organizations, backup, batch, application-autoscaling, autoscaling, dax, s3control)
- [x] 1.2 Mount LocalEmu patch for S3 Control + missing EC2/IAM/RDS/SSM/Backup actions; wire load-at-startup

## 2. Smoke + baseline (#196)

- [x] 2.1 `bin/prowler-smoke.sh` — env-isolated config, endpoint with account-id DNS, `--log-level ERROR`, distinct failing APIs
- [x] 2.2 Checked-in baseline; smoke fails if failing-API count rises
- [x] 2.3 Wire into `bin/e2e.sh`

## 3. Docs (#196)

- [x] 3.1 `docs/prowler.md` (isolation + how to run)
- [x] 3.2 README status row; smoke matrix / test-paths

## 4. Ship

- [x] 4.1 Gap check → Debt #197 (full catalog), #198 (empty-read depth)
- [ ] 4.2 PR Closes #196; board in-review
