# Post-health IaC re-apply hook for bin/stackwrangler and image CLI (#290).
# Source after ROOT (or DATA for image) and sw_env are available.
#
#   # shellcheck disable=SC1091
#   source "$ROOT/bin/stackwrangler-dev-apply-hook.sh"
#
# Runs when STACKWRANGLER_DEV_APPLY_HOOK / AWSBOX_DEV_APPLY_HOOK is set, or when
# the gitignored config file lists script paths. Failing apply exits non-zero.
# Does not require --dev yet (#288 will wire mode selection).

# Default gitignored config under the checkout / data dir (one script path per line).
dev_apply_hook_config_path() {
	local base="${STACKWRANGLER_DEV_APPLY_HOOK_ROOT:-${ROOT:-.}}"
	printf '%s\n' "${base%/}/.awsbox/dev-apply-hook"
}

# Resolve ordered list of hook script paths (stdout, one per line). Empty = skip.
dev_apply_hook_paths() {
	local hook conf line
	hook="$(sw_env STACKWRANGLER_DEV_APPLY_HOOK AWSBOX_DEV_APPLY_HOOK "")"
	if [[ -n "$hook" ]]; then
		printf '%s\n' "$hook"
		return 0
	fi
	conf="$(sw_env STACKWRANGLER_DEV_APPLY_HOOK_FILE AWSBOX_DEV_APPLY_HOOK_FILE "")"
	if [[ -z "$conf" ]]; then
		conf="$(dev_apply_hook_config_path)"
	fi
	if [[ ! -f "$conf" ]]; then
		return 0
	fi
	while IFS= read -r line || [[ -n "$line" ]]; do
		line="${line%%#*}"
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		[[ -z "$line" ]] && continue
		printf '%s\n' "$line"
	done <"$conf"
}

# Run configured hooks after emulator healthy. No-op when none configured.
run_dev_apply_hook() {
	local paths path rc
	paths="$(dev_apply_hook_paths || true)"
	if [[ -z "${paths//[$'\t\r\n']/}" ]]; then
		return 0
	fi
	while IFS= read -r path || [[ -n "$path" ]]; do
		[[ -z "$path" ]] && continue
		if [[ ! -e "$path" ]]; then
			echo "error: dev apply hook not found: ${path}" >&2
			echo "  set STACKWRANGLER_DEV_APPLY_HOOK to an executable script (docs/terraform-stackwrangler.md)" >&2
			return 1
		fi
		if [[ ! -x "$path" && ! -f "$path" ]]; then
			echo "error: dev apply hook is not a file: ${path}" >&2
			return 1
		fi
		echo "dev apply hook: ${path}"
		rc=0
		if [[ -x "$path" ]]; then
			"$path" || rc=$?
		else
			bash "$path" || rc=$?
		fi
		if [[ "$rc" -ne 0 ]]; then
			echo "error: dev apply hook failed (exit ${rc}): ${path}" >&2
			return "$rc"
		fi
	done <<<"$paths"
	return 0
}
