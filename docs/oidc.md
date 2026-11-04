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

`aws:ResourceTag/*` is evaluated for tagged IAM roles (and the services the enforcer already loads). `kms:ViaService`, `aws:SourceArn`, and service-origin `aws:SourceAccount` are not set by the calling service yet — an Allow that requires them fails closed. Follow-up: [#223](https://github.com/kgz/awsl/issues/223).
