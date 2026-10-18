## Context

Greenfield repo. Vision says LocalStack is the API + Lambda runtime; `awsbox` is the single entrypoint that starts it and configures profile `local`. Issue #2 is the first delivery.

## Goals / Non-Goals

**Goals:**

- One command brings LocalStack up and leaves CLI usable via `--profile local`
- Tear down cleans the container and optionally removes profile `local`
- Deterministic ports and fake account credentials documented

**Non-Goals:**

- Console, Serverless deploy, Lambda packaging
- Multi-account / multi-region simulation beyond one default region
- Shipping a bundled AWS CLI

## Decisions

1. **CLI language: Node (TypeScript) + thin shell entry**
   - Matches Serverless ecosystem users already have Node.
   - Alternative considered: Go binary — nicer UX later, slower to iterate for v1.

2. **Orchestration: Docker Compose file in repo + `docker compose` from CLI**
   - LocalStack Community image, port `4566`, services limited later; for this slice default LocalStack start is enough.
   - Alternative: spawn `docker run` ad hoc — harder to extend when console joins the compose stack.

3. **Profile name fixed: `local`**
   - Matches vision. Credentials: well-known LocalStack test keys (`test`/`test`) unless LocalStack config says otherwise.
   - Endpoint URL: `http://localhost:4566` with `s3` path-style addressing flagged in config.

4. **State dir: `.awsbox/` in project (gitignored) + touch `~/.aws/*` only for profile `local`**
   - Project-local compose project name avoids colliding with other LocalStack runs.

5. **No console process yet**
   - `up` only starts API stack; later changes add console service to the same compose.

## Risks / Trade-offs

- [Docker missing / permission] → Clear error from `awsbox up` with install hint
- [Profile `local` already exists for something else] → Refuse overwrite unless `--force`; document
- [LocalStack slow first pull] → Print progress; `status` shows healthy vs starting
- [WSL vs Windows Docker] → Document Docker Desktop WSL integration; endpoint still localhost from WSL

## Migration Plan

N/A (new). Rollback: `awsbox down` + delete profile `local` section.

## Open Questions

- Prefer `docker compose` v2 only, or also support podman?
- Exact default region string (`ap-southeast-2` vs `us-east-1`) — pick `us-east-1` for LocalStack defaults unless user sets `AWSBOX_REGION`
