## 1. Stack (#186)

- [x] 1.1 `.env.example` + `docker-compose.yml`: `AWSBOX_LAMBDA_DOCKER_FLAGS` → `LAMBDA_DOCKER_FLAGS`, default `--add-host=host.docker.internal:host-gateway`

## 2. Smoke (#186)

- [x] 2.1 `bin/lambda-vpc-smoke.sh`: VPC + subnet + SG, VPC Lambda, host HTTP server; happy (mapped name 200) + sad (unmapped name ENOTFOUND); cleans up
- [x] 2.2 Wire into `bin/e2e.sh`

## 3. Docs (#186)

- [x] 3.1 `docs/lambda-vpc.md` (setup, `.env` example, fidelity gaps)
- [x] 3.2 `docs/smoke-matrix.md`, `docs/test-paths.md`, README Lambda row

## 4. Ship

- [ ] 4.1 Gap check; PR Closes #186; board in-review
