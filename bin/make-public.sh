#!/usr/bin/env bash
# Prep / execute public visibility for kgz/stackwrangler (#413).
#
# Default: print blocker checklist + current privacy (never flips).
#   ./bin/make-public.sh --prep     → topics, description, try secret scanning (still private)
#   CONFIRM_PUBLIC=yes ./bin/make-public.sh --flip
#     → visibility=public + secret scanning / push protection, then remind branch protection
#
# Do NOT run --flip until README scrub (#402/#411), protection *script* (#412), and
# open public-ready blockers are green — see docs/public-release.md.
# Live protection (#431) is post-flip (or after Pro), not a pre-flip closer.
set -euo pipefail

OWNER="${GITHUB_OWNER:-kgz}"
REPO="${GITHUB_REPO:-stackwrangler}"
FULL="${OWNER}/${REPO}"

DO_PREP=0
DO_FLIP=0
for arg in "$@"; do
	case "$arg" in
		--prep) DO_PREP=1 ;;
		--flip) DO_FLIP=1 ;;
		-h|--help)
			sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "Unknown arg: $arg (use --prep and/or --flip)" >&2
			exit 1
			;;
	esac
done

api() {
	gh api -R "$FULL" "$@"
}

repo_api() {
	gh api "repos/${FULL}" "$@"
}

echo "=== ${FULL} public release helper (#413) ==="
priv="$(repo_api --jq '{private:.private,visibility:.visibility,description:.description,homepage:.homepage}')"
echo "Current: ${priv}"
echo

echo "=== Blockers (must be green or explicitly waived before --flip) ==="
# issue | why
BLOCKERS=(
	"402|Product README rewrite (no Project #8 / agent ops on landing)"
	"411|Board/workflow scrub from public README"
	"381|LICENSE + THIRD_PARTY on main"
	"305|User-facing rebrand far enough (debt #405/#406/#408 as needed)"
	"412|Branch protection script/docs shipped"
	"414|CONTRIBUTING + SECURITY (+ CODEOWNERS)"
)

any_open=0
for row in "${BLOCKERS[@]}"; do
	num="${row%%|*}"
	why="${row#*|}"
	state="$(gh issue view "$num" -R "$FULL" --json state --jq .state 2>/dev/null || echo MISSING)"
	printf '  #%s  %-8s  %s\n' "$num" "$state" "$why"
	if [[ "$state" != "CLOSED" ]]; then
		any_open=1
	fi
done
echo
echo "=== Post-flip (not a pre-flip closer) ==="
echo "  Immediately after visibility=public (or after GitHub Pro): ./bin/setup-branch-protection.sh"
echo "  Debt #431 tracks live protection apply — close it after that run, not before --flip."
echo
echo "  Project #8 may stay private — public clone UX must not require it."
echo "  Related open public-ready work: gh issue list -R ${FULL} --label public-ready --state open"
echo

if [[ "$any_open" -eq 1 ]]; then
	echo "Note: one or more checklist issues are still OPEN — do not --flip until waived."
	echo
fi

apply_meta() {
	echo "=== Prep: description / homepage / topics ==="
	# Keep product description; homepage empty until docs site ships (#403).
	repo_api -X PATCH \
		-f description='Local AWS feel — one account, real APIs, console on localhost (stackwrangler)' \
		-f homepage='' \
		--jq '{description,homepage,private}' >/dev/null
	echo "description/homepage updated"

	# Prefer aws / local-dev topics; avoid implying LocalStack affiliation.
	gh api -X PUT "repos/${FULL}/topics" \
		-H "Accept: application/vnd.github+json" \
		--input - <<'EOF' >/dev/null
{"names":["aws","local-development","iac","docker","terraform","cloudformation","s3","lambda"]}
EOF
	echo "topics set: aws, local-development, iac, docker, terraform, cloudformation, s3, lambda"

	echo "=== Prep: secret scanning / push protection / Dependabot alerts ==="
	set +e
	scan_out="$(repo_api -X PATCH --input - <<'EOF' 2>&1
{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" },
    "dependabot_security_updates": { "status": "enabled" }
  }
}
EOF
)"
	scan_ec=$?
	set -e
	if [[ "$scan_ec" -ne 0 ]]; then
		echo "$scan_out" >&2
		echo "warning: could not enable secret scanning yet (often needs public repo or GHAS)." >&2
		echo "         Re-run --prep after --flip, or enable in Settings → Code security." >&2
	else
		echo "secret scanning / push protection / Dependabot updates requested"
		repo_api --jq '.security_and_analysis // "null"'
	fi
}

if [[ "$DO_PREP" -eq 1 ]]; then
	apply_meta
	echo
fi

if [[ "$DO_FLIP" -eq 1 ]]; then
	if [[ "${CONFIRM_PUBLIC:-}" != "yes" ]]; then
		echo "Refusing --flip: set CONFIRM_PUBLIC=yes (blockers must be green)." >&2
		echo "Example: CONFIRM_PUBLIC=yes ./bin/make-public.sh --prep --flip" >&2
		exit 1
	fi
	if [[ "$any_open" -eq 1 && "${WAIVE_PUBLIC_BLOCKERS:-}" != "yes" ]]; then
		echo "Refusing --flip: checklist issues still OPEN." >&2
		echo "Waive only deliberately: WAIVE_PUBLIC_BLOCKERS=yes CONFIRM_PUBLIC=yes ./bin/make-public.sh --flip" >&2
		exit 1
	fi

	echo "=== Flip: visibility → public ==="
	repo_api -X PATCH -f visibility=public --jq '{private,visibility}'
	echo "Repo is public."

	# Scanning is free on public; enable again in case --prep was skipped / failed private.
	DO_PREP=1
	apply_meta

	echo
	echo "*** NEXT (do not skip): apply branch protection immediately ***"
	echo "    ./bin/setup-branch-protection.sh"
	echo "    Debt: #431 — PR-only main, CODEOWNERS review, no force-push"
	echo
	echo "After: verify clone URL / kgz/awsl redirect; confirm no Actions secrets needed for clone+run."
	exit 0
fi

echo "No visibility change (CONFIRM_PUBLIC not used / --flip not passed)."
echo "When blockers are green:"
echo "  CONFIRM_PUBLIC=yes ./bin/make-public.sh --prep --flip"
echo "  ./bin/setup-branch-protection.sh   # #412 / #431 — immediately after"
echo
repo_api --jq '"still private=" + (.private|tostring)'
