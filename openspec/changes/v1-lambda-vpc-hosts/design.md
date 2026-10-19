## Context

LocalEmu runs each function in its own Docker container on the emulator's network. `create-function --vpc-config` is accepted and echoed back, but has no network effect. Probe (2026-10-20): a VPC Lambda reached a host HTTP server at `172.17.0.1`, while `host.docker.internal` and an internal name returned `ENOTFOUND`. With `LAMBDA_DOCKER_FLAGS="--add-host=host.docker.internal:host-gateway --add-host=<name>:host-gateway"` all three returned 200.

## Decisions

- **Pass flags straight through.** One `.env` value, `AWSBOX_LAMBDA_DOCKER_FLAGS`, maps to `LAMBDA_DOCKER_FLAGS` in compose. No list-to-flags rendering: the Docker flag syntax is already the documented interface, and it also allows other flags (e.g. `--network`).
- **Default maps `host.docker.internal` only.** Internal names are per-project, so they live in each user's `.env`.
- **Same behaviour with or without `VpcConfig`.** The mapping applies to every function container. Documented as a known fidelity gap: in AWS, a non-VPC Lambda can't reach private hosts.

## Risks

- `host-gateway` needs Docker 20.10+. Older engines fail at container start; documented.
- Changing the flags needs an emulator restart (`./bin/awsbox up --force`).
