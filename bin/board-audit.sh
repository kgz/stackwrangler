#!/usr/bin/env bash
# Compare GitHub Project #8 status vs bin/board-tracker.tsv and optionally sync.
# Usage:
#   ./bin/board-audit.sh              # print drift report
#   ./bin/board-audit.sh --apply      # update board to match tracker
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TRACKER="$ROOT/bin/board-tracker.tsv"
APPLY=0

if [[ "${1:-}" == "--apply" ]]; then
	APPLY=1
elif [[ -n "${1:-}" ]]; then
	echo "Usage: $0 [--apply]" >&2
	exit 1
fi

if [[ ! -f "$TRACKER" ]]; then
	echo "Missing tracker: $TRACKER" >&2
	exit 1
fi

declare -A EXPECTED=()
while IFS=$'\t' read -r issue expected _rest; do
	[[ -z "${issue:-}" || "$issue" == \#* ]] && continue
	EXPECTED["$issue"]="$expected"
done < "$TRACKER"

fetch_board() {
	local cursor="" page
	while true; do
		if [[ -z "$cursor" ]]; then
			page="$(gh api graphql -f query='
query {
  user(login: "kgz") {
    projectV2(number: 8) {
      items(first: 100) {
        pageInfo { hasNextPage endCursor }
        nodes {
          content { ... on Issue { number } }
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
  }
}')"
		else
			page="$(gh api graphql -f query='
query($cursor: String!) {
  user(login: "kgz") {
    projectV2(number: 8) {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          content { ... on Issue { number } }
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
  }
}' -f cursor="$cursor")"
		fi
		echo "$page" | jq -r '
			.data.user.projectV2.items.nodes[]
			| select(.content != null)
			| "\(.content.number)\t\(.fieldValueByName.name // "?")"
		'
		local has_next end
		has_next="$(echo "$page" | jq -r '.data.user.projectV2.items.pageInfo.hasNextPage')"
		end="$(echo "$page" | jq -r '.data.user.projectV2.items.pageInfo.endCursor // empty')"
		[[ "$has_next" == "true" && -n "$end" ]] || break
		cursor="$end"
	done
}

normalize_status() {
	case "$1" in
		Backlog|backlog|todo) echo backlog ;;
		Ready|ready) echo ready ;;
		"In progress"|in-progress|in_progress) echo in-progress ;;
		"In review"|in-review|in_review) echo in-review ;;
		Done|done) echo done ;;
		*) echo "$1" ;;
	esac
}

declare -A BOARD=()
while IFS=$'\t' read -r num status; do
	[[ -n "${num:-}" ]] || continue
	BOARD["$num"]="$(normalize_status "$status")"
done < <(fetch_board)

drift=0
apply_backlog=() apply_ready=() apply_in_progress=() apply_in_review=() apply_done=()

for issue in $(printf '%s\n' "${!EXPECTED[@]}" | sort -n); do
	expected="${EXPECTED[$issue]}"
	actual="${BOARD[$issue]:-missing}"
	if [[ "$actual" == "$expected" ]]; then
		printf 'ok      #%s  %s\n' "$issue" "$expected"
		continue
	fi
	drift=1
	printf 'DRIFT    #%s  board=%s  tracker=%s\n' "$issue" "$actual" "$expected"
	case "$expected" in
		backlog) apply_backlog+=("$issue") ;;
		ready) apply_ready+=("$issue") ;;
		in-progress) apply_in_progress+=("$issue") ;;
		in-review) apply_in_review+=("$issue") ;;
		done) apply_done+=("$issue") ;;
	esac
done

if [[ "$drift" -eq 0 ]]; then
	echo "Board matches tracker."
	exit 0
fi

if [[ "$APPLY" -eq 0 ]]; then
	echo
	echo "Run with --apply to sync board from tracker."
	exit 1
fi

[[ ${#apply_backlog[@]} -gt 0 ]] && "$ROOT/bin/board-status.sh" backlog "${apply_backlog[@]}"
[[ ${#apply_ready[@]} -gt 0 ]] && "$ROOT/bin/board-status.sh" ready "${apply_ready[@]}"
[[ ${#apply_in_progress[@]} -gt 0 ]] && "$ROOT/bin/board-status.sh" in-progress "${apply_in_progress[@]}"
[[ ${#apply_in_review[@]} -gt 0 ]] && "$ROOT/bin/board-status.sh" in-review "${apply_in_review[@]}"
[[ ${#apply_done[@]} -gt 0 ]] && "$ROOT/bin/board-status.sh" done "${apply_done[@]}"
echo "Board synced from tracker."
