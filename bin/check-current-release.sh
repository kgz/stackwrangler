#!/usr/bin/env bash
# Guard: docs/CURRENT_RELEASE must be the *open* cut, not a shipped GitHub Release.
# Also fails if any open issues still carry a shipped release label (cut leftovers).
# Usage: ./bin/check-current-release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CUR_FILE="$ROOT/docs/CURRENT_RELEASE"
REPO="${GITHUB_REPOSITORY:-kgz/stackwrangler}"

if [[ ! -f "$CUR_FILE" ]]; then
	echo "error: missing $CUR_FILE" >&2
	exit 1
fi

CUR="$(tr -d '[:space:]' <"$CUR_FILE")"
if [[ ! "$CUR" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "error: CURRENT_RELEASE must look like v0.0.7 (got: $CUR)" >&2
	exit 1
fi

if gh release view "$CUR" --repo "$REPO" >/dev/null 2>&1; then
	echo "error: docs/CURRENT_RELEASE=$CUR but GitHub Release $CUR already exists." >&2
	echo "After cutting a release, bump CURRENT_RELEASE to the *next* open cut (./bin/release-tag.sh $CUR --next vX.Y.Z)." >&2
	exit 1
fi

# Shipped cuts: release tags from the API (works on older gh without `release list --json`).
mapfile -t SHIPPED < <(
	gh api "repos/${REPO}/releases?per_page=50" --jq '.[].tag_name' \
		| grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true
)

fail=0
for ver in "${SHIPPED[@]}"; do
	[[ "$ver" == "$CUR" ]] && continue
	count="$(gh api "repos/${REPO}/issues?labels=${ver}&state=open&per_page=5" --jq 'length' 2>/dev/null || echo 0)"
	if [[ "$count" != "0" ]]; then
		echo "error: open issues still labelled $ver (shipped cut). Re-place or unlabel leftovers:" >&2
		gh api "repos/${REPO}/issues?labels=${ver}&state=open&per_page=50" \
			--jq '.[] | "  #\(.number) \(.title)"' >&2 || true
		fail=1
	fi
done

if [[ "$fail" -ne 0 ]]; then
	exit 1
fi

echo "ok: CURRENT_RELEASE=$CUR (unshipped); no open leftovers on shipped cut labels"
