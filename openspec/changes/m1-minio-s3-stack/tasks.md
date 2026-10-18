## 1. MinIO compose (issue #8)

- [ ] 1.1 Add `docker-compose.yml` (MinIO API `9000`, volume, healthcheck)
- [ ] 1.2 Add `.env.example` + gitignore `.env`
- [ ] 1.3 README: copy env, `compose up`, ports

## 2. Profile `local`

- [ ] 2.1 `bin/awsbox-profile write|remove` (endpoint, keys, region, path-style)
- [ ] 2.2 Refuse overwrite unless `--force`; mark managed profile
- [ ] 2.3 Optional `bin/awsbox up|down` wrapping compose + profile write/remove

## 3. Smoke

- [ ] 3.1 Document smoke: `s3 mb`, `s3 ls`, `s3 cp`, `s3 rb`
- [ ] 3.2 Verify on this machine; note any WSL/Docker gotchas in README
