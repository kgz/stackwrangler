## Why

IAM is live. Next v1 track is Lambda so learners can list, create, and invoke functions on the same local account — console and `aws --profile local`.

## What Changes

- Enable Lambda (+ Logs) on LocalEmu with Docker socket for real runtimes
- Profile `local`: lambda/logs → `:4566` (with existing IAM/STS)
- Console Lambda area: list functions, create hello function, invoke + show payload
- CLI smoke + Playwright e2e

## Non-goals

- Full Lambda console parity (layers, VPC, aliases, event source mappings)
- Zip upload / Serverless Framework deploy (#22)
- API Gateway wiring (#20)
- Deep CloudWatch Logs UI (#21) — invoke may show LogResult only

## Capabilities

### New Capabilities

- `lambda-stack`: LocalEmu Lambda (+ logs) with Docker runtime
- `lambda-console`: Functions list, create hello, invoke result panel
- `lambda-invoke`: CLI/console invoke returns function response

### Modified Capabilities

- `aws-local-profile`: add lambda + logs service endpoints

## Impact

- `docker-compose.yml` (docker.sock, SERVICES), `bin/awsbox*`, console routes/SDK
- Issue: #19
