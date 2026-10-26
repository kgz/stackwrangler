#!/usr/bin/env bash
# Update GitHub Project #8 (awsl) card status for issues.
# Usage: ./bin/board-status.sh <backlog|ready|designing|in-progress|in-review|done> <issue-num> [issue-num...]
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
		echo "warning: GITHUB_PAT is set but rejected by GitHub — using gh login token instead" >&2
	fi

	export GITHUB_TOKEN="$(gh_stored_token)"
}

resolve_github_token

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <backlog|ready|in-progress|in-review|done> <issue-num> [issue-num...]" >&2
  exit 1
fi

STATUS_NAME="$1"
shift

case "$STATUS_NAME" in
  backlog|todo) OPT="dfa84092" ;;
  ready) OPT="ae0781e5" ;;
  designing) OPT="6199a95a" ;;
  in-progress|in_progress) OPT="99efdfee" ;;
  in-review|in_review) OPT="649b2f32" ;;
  done) OPT="023eb12d" ;;
  *)
    echo "Unknown status: $STATUS_NAME" >&2
    exit 1
    ;;
esac

PROJECT_ID="PVT_kwHOAI9yDM4BnjLa"
FIELD_ID="PVTSSF_lAHOAI9yDM4BnjLazhmHRjg"
PROJECT_NUMBER=8
REPO_OWNER="kgz"
REPO_NAME="awsl"
TMPDIR="${TMPDIR:-/tmp}/awsl-board-$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

for num in "$@"; do
  cat > "$TMPDIR/issue.graphql" <<EOF
query {
  repository(owner: "$REPO_OWNER", name: "$REPO_NAME") {
    issue(number: $num) {
      id
      projectItems(first: 10) {
        nodes {
          id
          project { number }
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
nodes = data['data']['repository']['issue']['projectItems']['nodes']
for n in nodes:
    if n.get('project', {}).get('number') == $PROJECT_NUMBER:
        print(n['id'])
        break
" 2>/dev/null) || true

  if [[ -z "$item_id" ]]; then
    node_id=$(echo "$issue_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['repository']['issue']['id'])")
    cat > "$TMPDIR/add.json" <<EOF
{"query":"mutation(\$p:ID!,\$c:ID!){ addProjectV2ItemById(input:{projectId:\$p contentId:\$c}){ item { id } } }","variables":{"p":"$PROJECT_ID","c":"$node_id"}}
EOF
    item_id=$(gh api graphql --input "$TMPDIR/add.json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['addProjectV2ItemById']['item']['id'])")
    echo "#$num added to project"
  fi

  cat > "$TMPDIR/update.json" <<EOF
{"query":"mutation(\$p:ID!,\$i:ID!,\$f:ID!,\$o:String!){ updateProjectV2ItemFieldValue(input:{projectId:\$p itemId:\$i fieldId:\$f value:{singleSelectOptionId:\$o}}){ projectV2Item { id } } }","variables":{"p":"$PROJECT_ID","i":"$item_id","f":"$FIELD_ID","o":"$OPT"}}
EOF
  gh api graphql --input "$TMPDIR/update.json" >/dev/null
  echo "#$num -> $STATUS_NAME"
done
