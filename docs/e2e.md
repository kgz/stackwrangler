# End-to-end tests

We use two complementary layers against the **real** local stack (not mocked S3):

| Layer | Tool | What |
|-------|------|------|
| CLI | `./smokes/s3/s3-parity.sh` | Day-to-day `aws s3` / `s3api` vs profile `local` |
| UI | **Playwright** (`console/e2e`) | Console flows; asserts CLI sees the same data |

## Why Playwright

Standard for browser e2e on React apps: real Chromium, file upload, traces on failure. Cypress is fine too; Playwright is the default here.

## Local + CI

| Layer | When | What |
|-------|------|------|
| Free-ci parity | PRs + `main` | `.github/workflows/parity-free.yml` → `./bin/parity run --suite free-ci --target local` (#675) |
| Curated smokes | PRs + `main` | `.github/workflows/smokes-ci.yml` → `./bin/ci-smokes.sh` (#807) — org-path + core happy/authz; LocalEmu only |
| Full e2e | Local only | `./bin/e2e.sh` — broader smokes + Playwright (+ optional ELBv2 / Prowler) |

Both CI workflows use `pull_request` (re-runs on each new commit) and `push` to `main`. Public Actions; no real AWS.

```bash
./bin/stackwrangler up   # ./bin/awsbox is a shim to the same CLI
./bin/ci-smokes.sh    # same suite as GitHub Actions
./bin/e2e.sh          # full local e2e (starts Vite / Playwright if needed)
# or separately:
./smokes/s3/s3-parity.sh
cd console && yarn playwright test
cd console && yarn playwright test --ui   # interactive
```

Needs: Docker, AWS CLI v2, Node 20+, yarn (Playwright / full e2e only).

IaC smokes (LocalEmu `:4566`): `./smokes/iac/iac-smoke.sh`, `./smokes/iac/cfn-smoke.sh`, `./smokes/iac/cfn-lifecycle-smoke.sh`, `./smokes/iac/cfn-caller-iam-smoke.sh`, `./smokes/iac/cfn-path-scoped-role-smoke.sh`, `./smokes/iac/cdk-smoke.sh`, `./smokes/iac/sam-smoke.sh`, `./smokes/iac/serverless-v3-smoke.sh`, `./smokes/iac/serverless-v3-sad-smoke.sh`, `./smokes/iac/serverless-v4-smoke.sh`, `./smokes/iac/serverless-v4-workspace-smoke.sh`, `./smokes/iac/serverless-v4-role-arn-smoke.sh`, `./smokes/iac/sls-aws-redirect-no-deps-smoke.sh` ([docs/serverless-stackwrangler.md](serverless-stackwrangler.md)).
