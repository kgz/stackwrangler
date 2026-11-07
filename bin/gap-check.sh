#!/usr/bin/env bash
# Cheap post-ticket gap scan. Does not file issues — agent must.
# Usage: ./bin/gap-check.sh [parent-issue-num]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARENT="${1:-}"
cd "$ROOT"

echo "=== stackwrangler gap-check ${PARENT:+(parent #${PARENT})} ==="
echo
echo "Rubric: docs/gap-check.md"
echo "Answer each; absorb small gaps into this PR, else open scored Debt / Doc: for NO / PARTIAL without a follow-up."
echo
cat <<'EOF'
[ ] Data plane real for what we claimed?
[ ] Authz under workload principal smoked (not only admin)?
[ ] Console: create/update/detail not stubbed/disabled without Debt ticket?
[ ] v1 skipped an AWS console UI for this service? Debt filed (or N/A — AWS has no such UI)?
[ ] Web UI went through Open Design (`designing` + mocks in design/stackwrangler-console/ using design/stackwrangler/) before React?
[ ] Dead controls: unwired = disabled + title="To implement" (+ Debt if v1); never-ship = omitted; no enabled no-ops?
[ ] No silent sidecar/bridge without Debt ticket + docs link?
[ ] README/docs status row links a Debt issue for Partial/Sidecar?
[ ] Tracker + board backlog updated for any new Debt / Doc: tickets?
[ ] docs/smoke-matrix.md updated (happy + sad columns)?
[ ] docs/test-paths.md lists every new path (searchable)?
[ ] Public docs: docs-site / interactions page updated in this PR, or Doc: filed?
[ ] Screenshot: console/UI shot captured via ./bin/docs-capture.sh, or Doc: filed / N/A?
[ ] Interaction edge: new cross-service path has catalog page, or Doc: filed?
EOF
echo

echo "=== Path rubric present? ==="
[[ -f docs/test-paths.md ]] && echo "OK docs/test-paths.md" || echo "MISSING docs/test-paths.md"
echo

echo "=== Smoke matrix (sad-path gaps) ==="
if [[ -f docs/smoke-matrix.md ]]; then
	rg -n '\| \*\*no\*\*|^\| [^|]+ \| yes \| \*\*no\*\*' docs/smoke-matrix.md 2>/dev/null | head -30 || \
		rg -n '\| no \|' docs/smoke-matrix.md 2>/dev/null | head -30 || true
else
	echo "MISSING docs/smoke-matrix.md"
fi
echo

echo "=== Heuristic hits (console / docs) ==="
# Disabled primary actions & "not wired" copy in UI
if command -v rg >/dev/null 2>&1; then
	rg -n --glob 'console/src/**/*.{tsx,ts}' \
		-e 'disabled' \
		-e 'Not wired' \
		-e 'not wired' \
		-e 'Use \./bin/' \
		-e 'Use CLI' \
		-e 'smoke' \
		-e 'title="Use' \
		-e 'empty states' \
		-e 'LocalEmu list-' \
		-e 'sidecar' \
		-e 'bridge' \
		2>/dev/null | head -80 || true
	echo
	echo "--- README Partial/Sidecar rows missing github issue links (heuristic) ---"
	rg -n --glob 'README.md' 'Partial|Sidecar|Control plane' 2>/dev/null | head -40 || true
	echo
	echo "--- Docs calling out limits / later ---"
	rg -n --glob 'docs/*.md' -e 'not wired' -e 'Backlog' -e 'debt' -e 'Sidecar' -e 'Partial' -e 'later' 2>/dev/null | head -40 || true
else
	echo "(install ripgrep for heuristic scan)"
fi

echo
echo "=== Open Debt: / Doc: issues (sample) ==="
if command -v gh >/dev/null 2>&1; then
	gh issue list --repo kgz/stackwrangler --state open --limit 20 --search 'Debt in:title' \
		--json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null || true
	gh issue list --repo kgz/stackwrangler --state open --limit 20 --search 'Doc: in:title' \
		--json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null || true
fi

echo
echo "=== Interactions catalog present? ==="
[[ -f docs-site/guide/interactions/index.md ]] && echo "OK docs-site/guide/interactions/index.md" \
	|| echo "MISSING docs-site/guide/interactions/index.md"
[[ -f docs/docs-catalog.md ]] && echo "OK docs/docs-catalog.md" || echo "MISSING docs/docs-catalog.md"
echo

echo "Done. If anything half-baked shipped in #${PARENT:-this PR}: absorb small gaps into this PR, else file scored Debt / Doc: — before board done."
echo "Debt/Doc: pillar + Impact/Effort (./bin/issue-score.sh); release label only if cut gate matches — never auto CURRENT_RELEASE (docs/gap-check.md · docs/docs-catalog.md)."
