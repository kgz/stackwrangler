#!/usr/bin/env bash
# List parent + slices under examples/serverless-v3-rest and report pass/fail/gap.
# Does not start awsbox. Parent uses serverless-v3-smoke.sh; slices declare their smoke in README.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EX="$ROOT/examples/serverless-v3-rest"

printf '%-18s %-8s %s\n' "SLICE" "STATUS" "NOTE"
printf '%-18s %-8s %s\n' "-----" "------" "----"

parent_ok=0
if [[ -f "$EX/serverless.yml" && -f "$ROOT/smokes/iac/serverless-v3-smoke.sh" ]]; then
	parent_ok=1
	printf '%-18s %-8s %s\n' "(parent)" "ready" "./smokes/iac/serverless-v3-smoke.sh"
else
	printf '%-18s %-8s %s\n' "(parent)" "gap" "missing serverless.yml or smoke script"
fi

shopt -s nullglob
slices=("$EX"/slices/*/)
if [[ ${#slices[@]} -eq 0 ]]; then
	printf '%-18s %-8s %s\n' "(slices)" "none" "other tickets add slices/<name>/"
else
	for d in "${slices[@]}"; do
		name="$(basename "$d")"
		if [[ -f "${d}serverless.yml" || -f "${d}template.yaml" ]]; then
			printf '%-18s %-8s %s\n' "$name" "present" "see slice README / owning ticket smoke"
		else
			printf '%-18s %-8s %s\n' "$name" "gap" "no serverless.yml / template.yaml"
		fi
	done
fi

[[ "$parent_ok" == "1" ]] || exit 1
