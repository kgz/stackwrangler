# IAM OIDC and PassRole

Local CI trust checks: which GitHub-style `sub` can assume which role, and which service a caller may pass a role to.

```bash
./bin/stackwrangler up
./smokes/security/oidc-smoke.sh
```

Issuer for tests is `https://awsbox.local/oidc`. `bin/oidc-mint.py` generates a local RSA key + JWKS under `localemu-patches/oidc/` on first use (gitignored — not committed), then signs JWTs (`--sub`, `--aud`). LocalEmu verifies against the mounted JWKS at `/opt/awsbox/oidc`.

Trust-policy condition keys are `<provider-host-and-path>:sub` and `:aud`, for example `awsbox.local/oidc:sub`. `StringEquals` and `StringLike` are evaluated. Other string claims on the token are available the same way.

`repo:org/*` matches every repository in that org, including feature branches. That is the over-broad pattern this smoke is here to catch. Prefer `repo:org/app:environment:prod` (or an equally specific `sub`).

`iam:PassRole` is checked when a non-root caller passes a role ARN to a service (`Role`, `RoleArn`, `taskRoleArn`, `executionRoleArn`, …). The request context includes `iam:PassedToService` (`events.amazonaws.com`, `states.amazonaws.com`, `lambda.amazonaws.com`, …). Root keys skip this check.

`iam:PermissionsBoundary` is set on `CreateRole` (from the request's `--permissions-boundary`) and on `PutRolePolicy` / `AttachRolePolicy` / `DetachRolePolicy` / `DeleteRolePolicy` (from the target role's current boundary ARN). A deploy-role Allow conditioned on that key matches locally the same way it does on AWS ([#525](https://github.com/kgz/stackwrangler/issues/525)). Smoke: `./smokes/security/iam-permissions-boundary-key-smoke.sh`.

Request-parameter condition keys that are still missing include SNS `sns:Protocol` / `sns:Endpoint` on Subscribe ([#518](https://github.com/kgz/stackwrangler/issues/518)).

`aws:ResourceTag/*` is evaluated for tagged IAM roles (and the services the enforcer already loads). `kms:ViaService`, `aws:SourceArn`, and service-origin `aws:SourceAccount` are not set by the calling service yet — an Allow that requires them fails closed. Follow-up: [#223](https://github.com/kgz/awsl/issues/223).
