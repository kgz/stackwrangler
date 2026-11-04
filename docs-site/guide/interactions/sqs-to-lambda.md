# SQS → Lambda (event source mapping)

Queue messages trigger a Lambda via event source mapping. Credential refresh and authz depth vary by smoke; treat as **partial** until the ESM path you need is listed green in the matrix.

**Status:** partial · See matrix rows for SQS / Lambda ESM and related Debt tickets

## Sequence

1. Create queue + function + event source mapping.
2. Send message; function consumes.
3. Confirm mapping enabled; sad paths depend on the specific smoke (role delete, deny, etc.).

## Prove it

Search [test-paths](https://github.com/kgz/stackwrangler/blob/main/docs/test-paths.md) for `SQS` / `event source` / `ESM`, then run the named `./bin/*-smoke.sh`. Do not claim unlisted ESM behaviours.
