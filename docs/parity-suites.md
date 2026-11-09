# Dual-target parity suites

Permanent, re-runnable checks that exercise the **same assertions** against LocalEmu (`local`) and real AWS (`real`). Catalog + runner live in-repo; real runs always need an explicit cost approval flag.

```bash
./bin/parity list
./bin/parity list --suite free-ci
./bin/parity list --tier free

# Local only (automation-friendly; no --approve-cost)
./bin/parity run --tier free --target local

# Real AWS (prints cost/residual banner; refuses without flag)
./bin/parity run --suite v005 --target real --approve-cost

# One check, both targets
./bin/parity run --id scheduler-delivery --target both --approve-cost
```

## Layout

| Path | Role |
|------|------|
| [`smokes/parity/catalog.yaml`](../smokes/parity/catalog.yaml) | Registry: id, covers, cost tier, residual, suites, script |
| [`smokes/parity/lib/parity-common.sh`](../smokes/parity/lib/parity-common.sh) | Target setup, cleanup LIFO, fixture KMS helper |
| [`smokes/parity/checks/*.sh`](../smokes/parity/checks/) | Dual-mode check bodies (`PARITY_TARGET=local\|real`) |
| [`bin/parity`](../bin/parity) | `list` / `run` |
| Legacy `smokes/parity/aws-parity-*.sh` | Older monoliths; catalogued as `legacy-*` |

Local smokes under `smokes/{messaging,security}/` for these tickets are thin wrappers that `exec` the dual-mode check with `PARITY_TARGET=local` so `e2e.sh` keeps working.

## Cost tiers

| Tier | Meaning | Typical automation |
|------|---------|--------------------|
| **free** | Teardown → ~$0; no sticky residual when fixtures reused | CI / regular local; real with `--approve-cost` when you want |
| **low** | Short-lived cents-level metering; no multi-day residual | Manual or scheduled with approval |
| **high** | Sticky residual (new CMK 7-day pending delete, recovery windows) or teardown-fail risk | Manual only |

`--target real|both` always requires `--approve-cost`, even for `free` tier (agents and humans must opt in).

## KMS fixtures (do not stack CMKs)

Prefer existing fixture aliases (see [AGENTS.md](../AGENTS.md) / aws-cost-approval):

- Trust / ViaService: `alias/sw-parity-fixture-trust-via` (`AWSBOX_PARITY_KMS_KEY_ID`)
- batch10 encrypt/decrypt: `alias/sw-parity-fixture-batch10` (`AWSBOX_PARITY_KMS_BATCH_KEY_ID`)

`parity_resolve_kms_fixture` reuses the fixture when present. It creates + `schedule-key-deletion` (7-day minimum) only if the fixture is missing — that path is the residual called out in the catalog.

## Adding a check

1. Write `smokes/parity/checks/<id>.sh` sourcing `parity-common.sh`, calling `parity_setup`, registering `on_cleanup`, ending with `parity_finish`.
2. Add a row to `catalog.yaml` (`cost_tier`, `est_cost`, `residual`, `suites`, `targets`).
3. Optionally thin-wrap a local smoke: `PARITY_TARGET=local; exec …/checks/<id>.sh`.
4. Document any sticky residual honestly — prefer designs that reuse fixtures.

## Suites (tags)

Examples in the catalog: `free-ci`, `v005`, `scheduler`, `iam`, `kms`, `legacy`, `trust`. Filter with `--suite`.

## Env

| Var | Meaning |
|-----|---------|
| `PARITY_TARGET` | `local` / `real` (set by runner) |
| `AWSBOX_PARITY_REGION` / `STACKWRANGLER_PARITY_REGION` | Real region (default `ap-southeast-2`) |
| `AWSBOX_PARITY_KEEP=1` / `--keep` | Skip teardown |
| `AWSBOX_PARITY_KMS_KEY_ID` | Override ViaService fixture alias |
| `AWSBOX_PARITY_SKIP_LOCAL` / `SKIP_REAL` | Legacy script toggles |
