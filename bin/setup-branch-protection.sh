#!/usr/bin/env bash
# Apply main-branch protection for kgz/stackwrangler (PR-only, no force-push).
# Classic protection / rulesets need a public repo or GitHub Pro while private.
# Run immediately after visibility=public (#413) or after enabling Pro — minimize the unprotected window.
set -euo pipefail

OWNER="${GITHUB_OWNER:-kgz}"
REPO="${GITHUB_REPO:-stackwrangler}"
BRANCH="${GITHUB_DEFAULT_BRANCH:-main}"
OWNER_USER="${GITHUB_MERGE_OWNER:-kgz}"

api() {
	gh api "$@"
}

echo "Target: ${OWNER}/${REPO}@${BRANCH} (merge owner: ${OWNER_USER})"

vis="$(api "repos/${OWNER}/${REPO}" --jq '{private:.private,visibility:.visibility}')"
echo "Repo: ${vis}"

# Optional repo setting (works on free private).
if api -X PATCH "repos/${OWNER}/${REPO}" -f delete_branch_on_merge=true --jq .delete_branch_on_merge >/dev/null; then
	echo "delete_branch_on_merge: true"
else
	echo "warning: could not set delete_branch_on_merge" >&2
fi

# User-owned repos cannot use restrictions (org-only). Keep write limited to OWNER_USER.
# CODEOWNERS (* @kgz) + require_code_owner_reviews → owner must approve before merge.
body="$(cat <<EOF
{
  "required_status_checks": null,
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
)"

set +e
prot_out="$(api -X PUT "repos/${OWNER}/${REPO}/branches/${BRANCH}/protection" \
	--input - <<<"${body}" 2>&1)"
prot_ec=$?
set -e

if [[ "${prot_ec}" -ne 0 ]]; then
	echo "${prot_out}" >&2
	if grep -q 'Upgrade to GitHub Pro or make this repository public' <<<"${prot_out}"; then
		echo >&2
		echo "Blocked: branch protection needs public visibility (#413) or GitHub Pro." >&2
		echo "Re-run this script immediately after either unlocks the API." >&2
		exit 2
	fi
	exit "${prot_ec}"
fi

echo "Branch protection applied on ${BRANCH}."
api "repos/${OWNER}/${REPO}/branches/${BRANCH}/protection" \
	--jq '{
          allow_force_pushes: .allow_force_pushes.enabled,
          allow_deletions: .allow_deletions.enabled,
          enforce_admins: .enforce_admins.enabled,
          required_pr: (.required_pull_request_reviews != null),
          require_code_owner_reviews: .required_pull_request_reviews.require_code_owner_reviews,
          required_approving_review_count: .required_pull_request_reviews.required_approving_review_count,
          dismiss_stale_reviews: .required_pull_request_reviews.dismiss_stale_reviews
        }'

echo
echo "Note: push restrictions (users=[${OWNER_USER}]) are org-only; keep write access to ${OWNER_USER} alone."
echo "Solo PRs authored by ${OWNER_USER} still need a CODEOWNERS approval (second account) while enforce_admins is on."
