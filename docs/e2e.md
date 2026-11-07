# End-to-end tests

We use two complementary layers against the **real** local stack (not mocked S3):

| Layer | Tool | What |
|-------|------|------|
| CLI | `./smokes/s3/s3-parity.sh` | Day-to-day `aws s3` / `s3api` vs profile `local` |
| UI | **Playwright** (`console/e2e`) | Console flows; asserts CLI sees the same data |

## Why Playwright

Standard for browser e2e on React apps: real Chromium, file upload, traces on failure. Cypress is fine too; Playwright is the default here.

## Local only

No GitHub Actions — run smokes locally (free-tier friendly).

```bash
./bin/stackwrangler up   # ./bin/awsbox is a shim to the same CLI
./bin/e2e.sh          # parity + Playwright (starts Vite if needed)
# or separately:
./smokes/s3/s3-parity.sh
cd console && yarn playwright test
cd console && yarn playwright test --ui   # interactive
```

Needs: Docker, AWS CLI v2, Node 20+, yarn.

IaC smokes (LocalEmu `:4566`): `./smokes/iac/iac-smoke.sh`, `./smokes/iac/cfn-smoke.sh`, `./smokes/iac/cfn-lifecycle-smoke.sh`, `./smokes/iac/cfn-caller-iam-smoke.sh`, `./smokes/iac/cdk-smoke.sh`, `./smokes/iac/sam-smoke.sh`, `./smokes/iac/serverless-v3-smoke.sh`, `./smokes/iac/serverless-v4-smoke.sh`, `./smokes/iac/serverless-v4-workspace-smoke.sh` ([docs/serverless-stackwrangler.md](serverless-stackwrangler.md)).
