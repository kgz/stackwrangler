## 1. S3 compose (issue #8)

- [x] 1.1 Add `docker-compose.yml` (SeaweedFS S3 `8333`, volume, healthcheck)
- [x] 1.2 Add `.env.example` + gitignore `.env`
- [x] 1.3 README: copy env, `awsbox up`, ports

## 2. Profile `local`

- [x] 2.1 `bin/awsbox-profile write|remove` (endpoint, keys, region, path-style)
- [x] 2.2 Refuse overwrite unless `--force`; mark managed profile
- [x] 2.3 `bin/awsbox up|down|status` wrapping compose + profile write/remove

## 3. Smoke

- [x] 3.1 Document smoke: `s3 mb`, `s3 ls`, `s3 cp`, `s3 rb`
- [x] 3.2 Verify on this machine; note WSL/Docker gotchas in README
