#!/usr/bin/env bash
# Update GitHub Project #8 (stackwrangler) card status for issues.
# Usage: ./bin/board-status.sh <backlog|ready|designing|in-progress|in-review|done> <issue-num> [issue-num...] [--agent=<id>]
#
# Agent claim (no per-agent labels): Project text field "Agent".
#   in-progress → set from --agent=… or $STACKWRANGLER_AGENT (else $AWSBOX_AGENT)
#   done|backlog|ready → clear Agent
#   in-review|designing → leave Agent unchanged
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

AGENT_ARG=""
ARGS=()
for a in "$@"; do
	case "$a" in
		--agent=*) AGENT_ARG="${a#--agent=}" ;;
		--agent)
			echo "Use --agent=<id> (e.g. --agent=cursor-batch-debt)" >&2
			exit 1
			;;
		*) ARGS+=("$a") ;;
	esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if [[ $# -lt 2 ]]; then
	echo "Usage: $0 <backlog|ready|designing|in-progress|in-review|done> <issue-num> [issue-num...] [--agent=<id>]" >&2
	echo "  Claim who picked up work via Project field Agent (not a GitHub label)." >&2
	echo "  in-progress: --agent=… or \$STACKWRANGLER_AGENT (legacy: \$AWSBOX_AGENT)." >&2
	exit 1
fi

STATUS_NAME="$1"
shift

# Project #8 Status option IDs (refresh if board-status updates fail).
case "$STATUS_NAME" in
	backlog|todo) OPT="dfa84092" ;;
	ready) OPT="ae0781e5" ;;
	designing|design) OPT="6199a95a" ;;
	in-progress|in_progress) OPT="99efdfee" ;;
	in-review|in_review) OPT="649b2f32" ;;
	done) OPT="023eb12d" ;;
	*)
		echo "Unknown status: $STATUS_NAME" >&2
		exit 1
		;;
esac

AGENT_VALUE=""
CLEAR_AGENT=0
case "$STATUS_NAME" in
	in-progress|in_progress)
		AGENT_VALUE="${AGENT_ARG:-${STACKWRANGLER_AGENT:-${AWSBOX_AGENT:-}}}"
		if [[ -z "$AGENT_VALUE" ]]; then
			echo "warning: in-progress without --agent=, STACKWRANGLER_AGENT, or AWSBOX_AGENT — Agent field not updated" >&2
		fi
		;;
	done|backlog|todo|ready)
		CLEAR_AGENT=1
		;;
esac

PROJECT_ID="PVT_kwHOAI9yDM4BnjLa"
FIELD_ID="PVTSSF_lAHOAI9yDM4BnjLazhmHRjg"
AGENT_FIELD_ID="PVTF_lAHOAI9yDM4BnjLazhnY2a4"
PROJECT_NUMBER=8
REPO_OWNER="kgz"
REPO_NAME="stackwrangler"
TMPDIR="${TMPDIR:-/tmp}/stackwrangler-board-$$"
mkdir -p "$TMPDIR"
trap 'rm -rf "$TMPDIR"' EXIT

set_agent_text() {
	local item="$1" text="$2"
	AGENT_ITEM="$item" AGENT_TEXT="$text" AGENT_FIELD_ID="$AGENT_FIELD_ID" PROJECT_ID="$PROJECT_ID" python3 -c '
import json, os
print(json.dumps({
  "query": "mutation($p:ID!,$i:ID!,$f:ID!,$t:String!){ updateProjectV2ItemFieldValue(input:{projectId:$p itemId:$i fieldId:$f value:{text:$t}}){ projectV2Item { id } } }",
  "variables": {
    "p": os.environ["PROJECT_ID"],
    "i": os.environ["AGENT_ITEM"],
    "f": os.environ["AGENT_FIELD_ID"],
    "t": os.environ["AGENT_TEXT"],
  },
}))
' >"$TMPDIR/agent.json"
	gh api graphql --input "$TMPDIR/agent.json" >/dev/null
}

clear_agent_text() {
	local item="$1"
	AGENT_ITEM="$item" AGENT_FIELD_ID="$AGENT_FIELD_ID" PROJECT_ID="$PROJECT_ID" python3 -c '
import json, os
print(json.dumps({
  "query": "mutation($p:ID!,$i:ID!,$f:ID!){ clearProjectV2ItemFieldValue(input:{projectId:$p itemId:$i fieldId:$f}){ projectV2Item { id } } }",
  "variables": {
    "p": os.environ["PROJECT_ID"],
    "i": os.environ["AGENT_ITEM"],
    "f": os.environ["AGENT_FIELD_ID"],
  },
}))
' >"$TMPDIR/agent.json"
	gh api graphql --input "$TMPDIR/agent.json" >/dev/null
}

for num in "$@"; do
	cat >"$TMPDIR/issue.graphql" <<EOF
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
		cat >"$TMPDIR/add.json" <<EOF
{"query":"mutation(\$p:ID!,\$c:ID!){ addProjectV2ItemById(input:{projectId:\$p contentId:\$c}){ item { id } } }","variables":{"p":"$PROJECT_ID","c":"$node_id"}}
EOF
		item_id=$(gh api graphql --input "$TMPDIR/add.json" | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['addProjectV2ItemById']['item']['id'])")
		echo "#$num added to project"
	fi

	cat >"$TMPDIR/update.json" <<EOF
{"query":"mutation(\$p:ID!,\$i:ID!,\$f:ID!,\$o:String!){ updateProjectV2ItemFieldValue(input:{projectId:\$p itemId:\$i fieldId:\$f value:{singleSelectOptionId:\$o}}){ projectV2Item { id } } }","variables":{"p":"$PROJECT_ID","i":"$item_id","f":"$FIELD_ID","o":"$OPT"}}
EOF
	gh api graphql --input "$TMPDIR/update.json" >/dev/null

	if [[ -n "$AGENT_VALUE" ]]; then
		set_agent_text "$item_id" "$AGENT_VALUE"
		echo "#$num -> $STATUS_NAME (Agent=$AGENT_VALUE)"
	elif [[ "$CLEAR_AGENT" -eq 1 ]]; then
		clear_agent_text "$item_id"
		echo "#$num -> $STATUS_NAME (Agent cleared)"
	else
		echo "#$num -> $STATUS_NAME"
	fi
done
