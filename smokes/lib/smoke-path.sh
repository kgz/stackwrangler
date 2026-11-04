#!/usr/bin/env bash
# Resolve a smoke basename (e.g. lambda-smoke) to $ROOT/smokes/<area>/<name>.sh
# Requires ROOT to be set to the repo root.
smoke_path() {
	local name="${1%.sh}"
	local found=""
	local f
	while IFS= read -r f; do
		if [[ -n "$found" ]]; then
			echo "smoke_path: multiple matches for ${name}.sh under smokes/" >&2
			return 1
		fi
		found="$f"
	done < <(find "$ROOT/smokes" -type f -name "${name}.sh" ! -path '*/lib/*' 2>/dev/null)
	if [[ -z "$found" ]]; then
		echo "smoke_path: no smokes/**/${name}.sh" >&2
		return 1
	fi
	printf '%s\n' "$found"
}
