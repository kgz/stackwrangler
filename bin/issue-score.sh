#!/usr/bin/env bash
# Set Project #8 Impact / Effort number fields (1–5) for an issue.
# Usage:
#   ./bin/issue-score.sh <issue-num> --impact=N --effort=N
#   ./bin/issue-score.sh <issue-num>              # print current scores
#   ./bin/issue-score.sh <issue-num> --impact=5   # set one field
set -euo pipefail

gh_stored_token() {
	if gh auth token >/dev/null 2>&1; then
		gh auth token
		return 0
	fi
	python3 -c "import yaml, pathlib; print(yaml.safe_load(pathlib.Path('~/.config/gh/hosts.yml').expanduser().read_text())['github.com']['oauth_token'])"
}

resolve_github_token() {
	if [[ -n "${GITHUB_TOKEN:-}" ]]; then
		return 0
	fi
	local pat="${GITHUB_PAT:-}"
	if [[ -n "$pat" ]]; then
		if GITHUB_TOKEN="$pat" gh api user -q .login >/dev/null 2>&1; then
			export GITHUB_TOKEN="$pat"
			return 0
		fi
	fi
	export GITHUB_TOKEN="$(gh_stored_token)"
}

resolve_github_token

IMPACT=""
EFFORT=""
ARGS=()
for a in "$@"; do
	case "$a" in
		--impact=*) IMPACT="${a#--impact=}" ;;
		--effort=*) EFFORT="${a#--effort=}" ;;
		--help|-h)
			echo "Usage: $0 <issue-num> [--impact=1-5] [--effort=1-5]" >&2
			exit 0
			;;
		*) ARGS+=("$a") ;;
	esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [[ $# -lt 1 ]]; then
	echo "Usage: $0 <issue-num> [--impact=1-5] [--effort=1-5]" >&2
	exit 1
fi

NUM="$1"
PROJECT_ID="PVT_kwHOAI9yDM4BnjLa"
PROJECT_NUMBER=8
IMPACT_FIELD_ID="PVTF_lAHOAI9yDM4BnjLazhoyybM"
EFFORT_FIELD_ID="PVTF_lAHOAI9yDM4BnjLazhoyybc"
REPO_OWNER="kgz"
REPO_NAME="awsl"
TMPDIR="${TMPDIR:-/tmp}/awsl-score-$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

validate_score() {
	local name="$1" val="$2"
	[[ -z "$val" ]] && return 0
	if ! [[ "$val" =~ ^[1-5]$ ]]; then
		echo "error: $name must be integer 1–5 (got '$val')" >&2
		exit 1
	fi
}

validate_score Impact "$IMPACT"
validate_score Effort "$EFFORT"

# Prefer stackwrangler if awsl redirects / renamed
if ! gh api "repos/$REPO_OWNER/$REPO_NAME" --jq .full_name >/dev/null 2>&1; then
	REPO_NAME="stackwrangler"
fi
# Detect rename via redirects
FULL=$(gh api "repos/$REPO_OWNER/awsl" --jq .full_name 2>/dev/null || echo "$REPO_OWNER/$REPO_NAME")
REPO_NAME="${FULL#*/}"
REPO_OWNER="${FULL%/*}"

cat >"$TMPDIR/issue.graphql" <<EOF
query {
  repository(owner: "$REPO_OWNER", name: "$REPO_NAME") {
    issue(number: $NUM) {
      id
      title
      projectItems(first: 20) {
        nodes {
          id
          project { number }
          fieldValues(first: 30) {
            nodes {
              ... on ProjectV2ItemFieldNumberValue {
                field { ... on ProjectV2FieldCommon { name } }
                number
              }
            }
          }
        }
      }
    }
  }
}
EOF

issue_json=$(gh api graphql -F "query=@$TMPDIR/issue.graphql")
item_id=$(echo "$issue_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
issue = data['data']['repository']['issue']
if issue is None:
    sys.exit('issue not found')
nodes = issue['projectItems']['nodes']
for n in nodes:
    if n.get('project', {}).get('number') == $PROJECT_NUMBER:
        print(n['id'])
        break
" 2>/dev/null) || true

if [[ -z "${item_id:-}" ]]; then
	node_id=$(echo "$issue_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['repository']['issue']['id'])")
	cat >"$TMPDIR/add.json" <<EOF
{"query":"mutation(\$p:ID!,\$c:ID!){ addProjectV2ItemById(input:{projectId:\$p contentId:\$c}){ item { id } } }","variables":{"p":"$PROJECT_ID","c":"$node_id"}}
EOF
	item_id=$(gh api graphql --input "$TMPDIR/add.json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['addProjectV2ItemById']['item']['id'])")
	echo "#$NUM added to project"
fi

read_scores() {
	echo "$issue_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
nodes = data['data']['repository']['issue']['projectItems']['nodes']
impact = effort = None
for n in nodes:
    if n.get('project', {}).get('number') != $PROJECT_NUMBER:
        continue
    for fv in n.get('fieldValues', {}).get('nodes', []):
        if not fv:
            continue
        name = (fv.get('field') or {}).get('name')
        num = fv.get('number')
        if name == 'Impact':
            impact = num
        elif name == 'Effort':
            effort = num
print(f'Impact={impact if impact is not None else \"unset\"}')
print(f'Effort={effort if effort is not None else \"unset\"}')
"
}

set_number() {
	local field_id="$1" value="$2"
	FIELD_ID="$field_id" ITEM_ID="$item_id" VAL="$value" PROJECT_ID="$PROJECT_ID" python3 -c '
import json, os
print(json.dumps({
  "query": "mutation($p:ID!,$i:ID!,$f:ID!,$n:Float!){ updateProjectV2ItemFieldValue(input:{projectId:$p itemId:$i fieldId:$f value:{number:$n}}){ projectV2Item { id } } }",
  "variables": {
    "p": os.environ["PROJECT_ID"],
    "i": os.environ["ITEM_ID"],
    "f": os.environ["FIELD_ID"],
    "n": float(os.environ["VAL"]),
  },
}))
' >"$TMPDIR/set.json"
	gh api graphql --input "$TMPDIR/set.json" >/dev/null
}

if [[ -z "$IMPACT" && -z "$EFFORT" ]]; then
	title=$(echo "$issue_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['repository']['issue']['title'])")
	echo "#$NUM $title"
	read_scores
	exit 0
fi

[[ -n "$IMPACT" ]] && set_number "$IMPACT_FIELD_ID" "$IMPACT"
[[ -n "$EFFORT" ]] && set_number "$EFFORT_FIELD_ID" "$EFFORT"

# refresh
issue_json=$(gh api graphql -F "query=@$TMPDIR/issue.graphql")
echo "#$NUM scored"
[[ -n "$IMPACT" ]] && echo "  Impact=$IMPACT"
[[ -n "$EFFORT" ]] && echo "  Effort=$EFFORT"
