## Context

LocalEmu already serves IAM/STS/S3 on `:4566`. Lambda needs the Docker socket to spawn runtime containers. SeaweedFS stays on `:8333`.

## Goals / Non-Goals

**Goals:**

- `aws --profile local lambda list-functions` works after `awsbox up`
- Console `/lambda`: list, create hello Node function, invoke, show response
- e2e covers create + invoke path

**Non-Goals:**

- Zip upload UI (#22), APIGW, full Logs console

## Decisions

1. **LocalEmu Lambda with Docker socket** — real `nodejs18.x` (or `nodejs20.x`) runtime containers; `user: root` on WSL/Desktop so socket works.

2. **Reuse Vite `/aws-iam` proxy** as generic emu gateway (same origin) for Lambda SDK calls — rename env mentally to “emu proxy”; keep path `/aws-iam` to avoid churn (or alias `/aws-emu`). Prefer adding `/aws-emu` and point both IAM + Lambda at it; keep `/aws-iam` rewrite for compat.

3. **Hello function = embedded zip bytes** — tiny `index.handler` Node zip; create role `awsbox-lambda-basic` once.

4. **SERVICES=iam,sts,s3,lambda,logs** — logs for future #21 and Invoke LogResult.

## Risks / Trade-offs

- [Docker-in-Docker / socket perms on WSL] → `user: root` + mount `/var/run/docker.sock`
- [Cold start pull of Lambda images] → first invoke slow; e2e timeout 60s+
- [IAM_ENFORCEMENT vs Lambda role] → root keys bypass; attach basic trust for created role

## Open Questions

- None for #19; #22 owns deploy-from-zip.
