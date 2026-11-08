#!/usr/bin/env bash
# Gate high-cost LocalEmu / e2e work so batch workers do not OOM the host.
#
# Usage:
#   ./bin/batch-resource-gate.sh check          # exit 0 if OK to bring a stack up
#   ./bin/batch-resource-gate.sh check --need-up # same; require capacity for one more stack
#   ./bin/batch-resource-gate.sh status         # print counts (always 0)
#   ./bin/batch-resource-gate.sh down-others [<keep-project>]
#       Tear down other awsl-wt-* / batch compose projects (keeps <keep-project> if set).
#
# Env (optional):
#   BATCH_MAX_LOCALEMU_STACKS  default 1
#   BATCH_MIN_AVAIL_GIB        default 4
set -euo pipefail

MAX_STACKS="${BATCH_MAX_LOCALEMU_STACKS:-1}"
MIN_AVAIL_GIB="${BATCH_MIN_AVAIL_GIB:-4}"

list_stack_projects() {
	docker ps -a --format '{{.Names}}' 2>/dev/null \
		| sed -n \
			-e 's/-localstack-1$//p' \
			-e 's/-s3-1$//p' \
			-e 's/-ecr-registry-1$//p' \
			-e 's/-aws-redirect-1$//p' \
		| sort -u \
		| grep -E '^(awsl-wt-|stackwrangler)' || true
}

avail_gib() {
	# MemAvailable (kB) → GiB
	awk '/MemAvailable:/ { printf "%.1f", $2/1024/1024; exit }' /proc/meminfo
}

cmd="${1:-check}"
shift || true

case "$cmd" in
	status)
		projects="$(list_stack_projects)"
		n=0
		[[ -n "$projects" ]] && n="$(printf '%s\n' "$projects" | grep -c . || true)"
		echo "localemu_stacks=$n (max=$MAX_STACKS)"
		echo "avail_gib=$(avail_gib) (min=$MIN_AVAIL_GIB)"
		[[ -n "$projects" ]] && printf '%s\n' "$projects" | sed 's/^/  /'
		exit 0
		;;
	down-others)
		keep="${1:-}"
		list_stack_projects | while read -r p; do
			[[ -z "$p" ]] && continue
			[[ -n "$keep" && "$p" == "$keep" ]] && continue
			# Never auto-down a bare "stackwrangler" project without keep= — user may own it.
			# Batch worktrees are awsl-wt-*; tear those. Also tear awsl-wt-batch-*.
			case "$p" in
				awsl-wt-*) ;;
				*) continue ;;
			esac
			echo "down $p"
			docker compose -p "$p" down --remove-orphans >/dev/null 2>&1 || true
		done
		exit 0
		;;
	check)
		need_up=0
		for a in "$@"; do
			case "$a" in
				--need-up) need_up=1 ;;
			esac
		done
		projects="$(list_stack_projects)"
		n=0
		[[ -n "$projects" ]] && n="$(printf '%s\n' "$projects" | grep -c . || true)"
		avail="$(avail_gib)"
		ok=1
		# count only awsl-wt-* toward the stack cap (user's default stackwrangler allowed)
		wt_n=0
		if [[ -n "$projects" ]]; then
			wt_n="$(printf '%s\n' "$projects" | grep -cE '^awsl-wt-' || true)"
		fi
		if [[ "$need_up" -eq 1 && "$wt_n" -ge "$MAX_STACKS" ]]; then
			echo "batch-resource-gate: refuse up — $wt_n awsl-wt-* stack(s) already (max $MAX_STACKS)" >&2
			printf '%s\n' "$projects" | grep -E '^awsl-wt-' | sed 's/^/  /' >&2 || true
			echo "  tip: ./bin/batch-resource-gate.sh down-others" >&2
			ok=0
		fi
		# awk compare avail < min
		if awk -v a="$avail" -v m="$MIN_AVAIL_GIB" 'BEGIN { exit !(a+0 < m+0) }'; then
			echo "batch-resource-gate: refuse — avail ${avail}GiB < min ${MIN_AVAIL_GIB}GiB" >&2
			ok=0
		fi
		if [[ "$ok" -ne 1 ]]; then
			exit 1
		fi
		echo "batch-resource-gate: ok (awsl-wt stacks=$wt_n/$MAX_STACKS avail=${avail}GiB)"
		exit 0
		;;
	*)
		echo "Usage: $0 {check [--need-up]|status|down-others [keep-project]}" >&2
		exit 2
		;;
esac
