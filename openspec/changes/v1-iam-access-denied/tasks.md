## 1. LocalStack + profile

- [x] 1.1 Add LocalStack service to `docker-compose.yml` (IAM/STS/S3, `:4566`, shared keys)
- [x] 1.2 Extend `.env.example` with `AWSBOX_IAM_ENDPOINT`
- [x] 1.3 Update `awsbox-profile` for per-service endpoints (S3 SeaweedFS, IAM/STS LocalStack)
- [x] 1.4 Update `awsbox up` health wait for LocalStack + console env vars

## 2. CLI AccessDenied lab

- [x] 2.1 Add `bin/iam-access-denied.sh` (deny user → ListBuckets → assert AccessDenied)
- [x] 2.2 Wire smoke into `bin/e2e.sh` or docs path

## 3. Console IAM

- [x] 3.1 Add `@aws-sdk/client-iam` + IAM/S3 LocalStack clients
- [x] 3.2 IAM Users page + fav-bar link to `/iam`
- [x] 3.3 AccessDenied lab UI (button → show denial)
- [x] 3.4 Playwright coverage for IAM list + AccessDenied lab

## 4. Ship

- [ ] 4.1 Tracker `#18` → done after merge; PR `Closes #18`
