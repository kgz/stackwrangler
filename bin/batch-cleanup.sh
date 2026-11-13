#!/usr/bin/env bash
# Ticket-batch / orchestrator cleanup. Safe for maintainer local excludes.
# Usage:
#   ./bin/batch-cleanup.sh worktrees [--force]     # remove ../<repo>-wt-* worktrees (not primary, not keep-list)
#   ./bin/batch-cleanup.sh branches                # delete local feature/batch branches with no open PR + fully merged
#   ./bin/batch-cleanup.sh stacks                  # down leftover awsl-wt-* compose / LocalEmu stacks
#   ./bin/batch-cleanup.sh check-primary           # assert primary is clean; refuse dangerous cleans
#   ./bin/batch-cleanup.sh all [--force]           # stacks → worktrees → branches → check-primary
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO_NAME="$(basename "$ROOT")"
PARENT="$(dirname "$ROOT")"
EXCLUDE_FILE="$ROOT/.git/info/exclude"
FORCE=0

usage() {
	sed -n '2,8p' "$0" | sed 's/^# //' >&2
}

die() { echo "error: $*" >&2; exit 1; }

# Paths that must never be wiped by cleanup (local excludes + common maintainer dirs).
# Do NOT put these in the public .gitignore — use .git/info/exclude only.
protected_paths() {
	local paths=()
	paths+=("local-only-notes")
	if [[ -f "$EXCLUDE_FILE" ]]; then
		while IFS= read -r line || [[ -n "$line" ]]; do
			[[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
			# strip trailing slash / globs to a top-level name when simple
			local p="${line%%/*}"
			p="${p#/}"
			[[ -n "$p" && "$p" != "*" && "$p" != "?" ]] && paths+=("$p")
		done <"$EXCLUDE_FILE"
	fi
	printf '%s\n' "${paths[@]}" | awk 'NF && !seen[$0]++'
}

assert_no_dangerous_clean() {
	# Refuse patterns that delete ignored / excluded maintainer files.
	if [[ "${BATCH_ALLOW_GIT_CLEAN_X:-}" == "1" ]]; then
		return 0
	fi
	echo "check: refusing git clean -x / -fdx (would delete .git/info/exclude paths)."
	echo "       protected: $(protected_paths | paste -sd, -)"
	echo "       use .git/info/exclude for private dirs — never public .gitignore."
}

cmd_check_primary() {
	assert_no_dangerous_clean
	local branch
	branch="$(git rev-parse --abbrev-ref HEAD)"
	if [[ "$branch" == "HEAD" ]]; then
		die "primary checkout is detached HEAD — expect branch main (or default)"
	fi
	local dirty
	dirty="$(git status --porcelain | wc -l | tr -d ' ')"
	if [[ "$dirty" != "0" ]]; then
		echo "warn: primary has $dirty dirty paths:" >&2
		git status -sb >&2
		exit 1
	fi
	# Ensure local-only notes still exist if exclude lists them and dir was expected
	if protected_paths | grep -qx 'local-only-notes'; then
		if [[ ! -d "$ROOT/local-only-notes" ]]; then
			echo "warn: local-only-notes/ missing (excluded locally; was it wiped by git clean?)" >&2
			echo "       recreate from backup; do not add to public .gitignore." >&2
			exit 1
		fi
	fi
	echo "ok: primary=$branch clean; local excludes respected"
}

# Keep: primary, architecture-map / experimental graph worktrees user may retain.
is_keep_worktree() {
	local wt="$1"
	[[ "$wt" == "$ROOT" ]] && return 0
	case "$wt" in
	*-wt-389-architecture-map|*-wt-architecture-map|*graph*|*experimental*)
		return 0
		;;
	esac
	return 1
}

cmd_worktrees() {
	assert_no_dangerous_clean
	local wt removed=0
	while IFS= read -r wt; do
		[[ -z "$wt" ]] && continue
		if is_keep_worktree "$wt"; then
			echo "keep $wt"
			continue
		fi
		echo "remove worktree $wt"
		if git worktree remove ${FORCE:+--force} "$wt" 2>/dev/null; then
			removed=$((removed + 1))
		else
			git worktree prune -v || true
			if [[ "$FORCE" == "1" ]]; then
				chmod -R u+w "$wt" 2>/dev/null || true
				rm -rf "$wt"
				removed=$((removed + 1))
			else
				echo "  failed — re-run with --force" >&2
			fi
		fi
	done < <(git worktree list --porcelain | awk '/^worktree /{print $2}')

	# Orphan dirs next to repo that look like batch worktrees but are unregistered
	local d
	for d in "$PARENT"/"$REPO_NAME"-wt-*; do
		[[ -e "$d" ]] || continue
		if is_keep_worktree "$d"; then
			echo "keep orphan-name $d"
			continue
		fi
		if git worktree list --porcelain | grep -Fq "worktree $d"; then
			continue
		fi
		echo "rm orphan $d"
		if [[ "$FORCE" == "1" ]]; then
			chmod -R u+w "$d" 2>/dev/null || true
			rm -rf "$d"
			removed=$((removed + 1))
		else
			echo "  skip (pass --force to delete orphans)" >&2
		fi
	done
	git worktree prune -v || true
	echo "removed≈$removed worktree(s); remaining:"
	git worktree list
}

cmd_branches() {
	git fetch --prune origin >/dev/null 2>&1 || true
	local b deleted=0
	local base
	base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || echo main)"
	while IFS= read -r b; do
		[[ "$b" == "main" || "$b" == "$base" || "$b" == "feature/389-architecture-map" ]] && continue
		# skip branches checked out in a remaining worktree
		if git worktree list | grep -q "\[$b\]"; then
			echo "skip checked-out $b"
			continue
		fi
		# keep if open PR
		if gh pr list --head "$b" --state open --json number --jq 'length' 2>/dev/null | grep -vq '^0$'; then
			echo "skip open-PR $b"
			continue
		fi
		if git merge-base --is-ancestor "$b" "origin/$base" 2>/dev/null; then
			echo "delete merged $b"
			git branch -D "$b" >/dev/null && deleted=$((deleted + 1)) || true
		else
			# closed-PR / abandoned feature leftovers — only with --force
			if [[ "$FORCE" == "1" && ( "$b" == feature/* || "$b" == batch/* || "$b" == release/* || "$b" == chore/* ) ]]; then
				echo "delete unmerged leftover $b (--force)"
				git branch -D "$b" >/dev/null && deleted=$((deleted + 1)) || true
			else
				echo "keep unmerged $b"
			fi
		fi
	done < <(git for-each-ref --format='%(refname:short)' refs/heads/)
	echo "deleted $deleted local branch(es)"
}

cmd_stacks() {
	if [[ -x "$ROOT/bin/batch-resource-gate.sh" ]]; then
		"$ROOT/bin/batch-resource-gate.sh" down-others || true
	fi
	# Best-effort: compose projects named like awsl-wt-*
	local proj
	while IFS= read -r proj; do
		[[ -z "$proj" ]] && continue
		echo "compose down -p $proj"
		docker compose -p "$proj" down --remove-orphans >/dev/null 2>&1 || true
	done < <(docker compose ls -q 2>/dev/null | grep -E 'awsl-wt-|stackwrangler-wt-' || true)
	echo "stacks: down-others attempted"
}

cmd_all() {
	cmd_stacks
	cmd_worktrees
	cmd_branches
	cmd_check_primary
}

ARGS=()
for a in "$@"; do
	case "$a" in
	--force) FORCE=1 ;;
	-h|--help) usage; exit 0 ;;
	*) ARGS+=("$a") ;;
	esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

cmd="${1:-}"
[[ -n "$cmd" ]] || { usage; exit 1; }
shift || true

case "$cmd" in
worktrees) cmd_worktrees ;;
branches) cmd_branches ;;
stacks) cmd_stacks ;;
check-primary) cmd_check_primary ;;
all) cmd_all ;;
*) usage; exit 1 ;;
esac
