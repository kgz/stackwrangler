# Public release (visibility flip)

`kgz/stackwrangler` stays **private** until product/docs/legal hygiene and branch protection are ready. The flip is deliberate — use [`bin/make-public.sh`](../bin/make-public.sh), not a drive-by Settings click.

## Before flip

| Check | Issues |
|-------|--------|
| Product README (no Project #8 / agent ops on landing) | #402, #411 |
| LICENSE + THIRD_PARTY on `main` | #381 |
| User-facing rebrand far enough | #305 (+ debt #405 / #406 / #408) |
| CONTRIBUTING + SECURITY + CODEOWNERS | #414 |
| Branch protection **script/docs** ready (not live apply) | #412 |
| Grep for real credentials / private URLs; `.env` / `labels.yaml` gitignored | this ticket’s prep |
| Project #8 may stay private — not required for public clone UX | — |

Live branch protection (Debt #431) is **after** public or GitHub Pro — not a pre-flip closer.

## Script

```bash
# Checklist + privacy only (safe)
./bin/make-public.sh

# Topics, description, try secret scanning (still private)
./bin/make-public.sh --prep

# Flip ONLY when blockers are green (or WAIVE_PUBLIC_BLOCKERS=yes)
CONFIRM_PUBLIC=yes ./bin/make-public.sh --prep --flip

# Immediately after public (or after GitHub Pro while private):
./bin/setup-branch-protection.sh
```

`--flip` without `CONFIRM_PUBLIC=yes` is refused. Open checklist issues also refuse `--flip` unless `WAIVE_PUBLIC_BLOCKERS=yes`.

## At flip

- Visibility → public
- Secret scanning + push protection (and Dependabot alerts if the API allows)
- Topics: `aws`, `local-development`, `iac`, … (no LocalStack affiliation implication)
- Description confirmed; homepage optional until docs site (#403)

## After

1. `./bin/setup-branch-protection.sh` (#431) — minimize the unprotected window
2. `gh api repos/kgz/stackwrangler --jq .private` → `false`
3. Confirm `kgz/awsl` redirect / clone URL
4. Confirm basic clone + `./bin/stackwrangler up` needs no Actions/Pages secrets

## Related

Execute-flip Debt: [#435](https://github.com/kgz/stackwrangler/issues/435). See also CONTRIBUTING (when present) for merge/protection notes.
