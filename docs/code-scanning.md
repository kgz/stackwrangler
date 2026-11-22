# Code scanning triage (CodeQL + related CI)

Agents and humans: treat security CI results with a **local-emulator threat model**. This repo is not a multi-tenant SaaS; the runtime is Docker/LocalEmu on a developer machine. Full agent rule: [.cursor/rules/codeql-emulator-triage.mdc](../.cursor/rules/codeql-emulator-triage.mdc). Summary in [AGENTS.md](../AGENTS.md).

## Config

| Piece | Role |
|-------|------|
| [.github/workflows/codeql.yml](../.github/workflows/codeql.yml) | Advanced CodeQL on `main` / PRs |
| [.github/codeql/codeql-config.yml](../.github/codeql/codeql-config.yml) | `paths-ignore`: `design/**`, `examples/**`, `docs-site/**`, `testdata/**` |

Ignore lists cut mock/sample noise. **Existing** alerts under ignored paths may still show until dismissed.

## Triage outcomes

| Outcome | When | Action |
|---------|------|--------|
| **Dismiss** | By-design local behaviour or analyzer name-confusion | GitHub alert → dismiss with reason + one-line comment pointing here |
| **Suppress in tree** | Rare; prefer path ignore or `# noqa` next to intentional bind | Keep comment citing this doc |
| **Optional hardening** | Real hygiene but breaks AWS-parity if done naively | Debt only if user wants it; do not block releases |
| **Fix** | Trust-boundary leak, real secret, reachable shipped CVE, unsafe `console/` sink | Issue + PR with smoke coverage |

## Common LocalEmu false positives

1. **Bind all interfaces** — private DNS, Transfer SFTP, ELBv2 listeners, ephemeral port allocate. Required so containers and host tooling can reach the emulator the way they reach AWS endpoints.
2. **“Clear-text secret” logs** — variables named `secret` / proximity to `MasterUserPassword` when the log line prints an ARN, id list, or boolean.
3. **Local secret meta files** — e.g. RDS host-port JSON under the stack data dir so published ports survive restart. Local-only; not a cloud KMS story.
4. **Design mocks** — static `design/stackwrangler-console/` JS using `innerHTML` for OD previews.
5. **Example egress / SSRF** — smoke Lambdas that fetch `event.publicUrl` / `peerUrl` on purpose ([examples/serverless-v3-rest/slices/egress](../examples/serverless-v3-rest/slices/egress/)).

## What we still care about

- Real credentials in git, images, or logs
- Console XSS / open redirects that affect the React app users run
- Dependencies we ship whose vulnerable code is on the local API path
- Anything that surprises a user who followed README “local only” and still loses host or cloud secrets

When unsure: dismiss with a written reason, or ask the maintainer — do **not** open a pile of lookalike security tickets.
