# End-to-end tests

We use two complementary layers against the **real** local stack (not mocked S3):

| Layer | Tool | What |
|-------|------|------|
| CLI | `./bin/s3-parity.sh` | Day-to-day `aws s3` / `s3api` vs profile `local` |
| UI | **Playwright** (`console/e2e`) | Console flows; asserts CLI sees the same data |

## Why Playwright

Standard for browser e2e on React apps: real Chromium, file upload, traces on failure, CI-friendly. Cypress is fine too; Playwright is the default here.

## Local

```bash
./bin/awsbox up
./bin/e2e.sh          # parity + Playwright (starts Vite if needed)
# or separately:
./bin/s3-parity.sh
cd console && yarn playwright test
cd console && yarn playwright test --ui   # interactive
```

Needs: Docker, AWS CLI v2, Node 20+, yarn.

## CI

`.github/workflows/e2e.yml` — compose up → CLI parity → Playwright.
