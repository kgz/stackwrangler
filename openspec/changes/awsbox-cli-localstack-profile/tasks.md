## 1. Package scaffold (issue #2)

- [ ] 1.1 Init Node/TypeScript package with `awsbox` bin entry (`package.json`, `tsconfig`, no `any`)
- [ ] 1.2 Add `docker-compose.yml` for LocalStack on `4566` and project name `awsbox`

## 2. Lifecycle commands

- [ ] 2.1 Implement `awsbox up` (compose up, wait healthy, print endpoint + profile)
- [ ] 2.2 Implement `awsbox down` and `awsbox status`
- [ ] 2.3 Fail clearly when Docker is missing or port is busy

## 3. AWS profile `local`

- [ ] 3.1 Write/update `~/.aws/credentials` + `config` for profile `local` (endpoint, region, keys)
- [ ] 3.2 Refuse overwrite of existing non-awsbox `local` unless `--force`
- [ ] 3.3 Support `awsbox down --remove-profile`

## 4. Docs + smoke

- [ ] 4.1 README: Docker requirement, `up`/`down`/`status`, `aws --profile local s3 ls`
- [ ] 4.2 Manual smoke: up → s3 ls → down (document in PR for #2)
