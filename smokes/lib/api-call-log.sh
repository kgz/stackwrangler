# shellcheck shell=bash
# Assertion helpers for the LocalEmu API call log (#194).
# Thin wrappers around smokes/lib/api_call_log_assert.py.
# Source after local-emu-env.sh (needs AWSBOX_IAM_ENDPOINT).
#
# Usage:
#   source "$ROOT/smokes/lib/api-call-log.sh"
#   api_call_log_clear
#   # … invoke workload …
#   api_call_log_assert_exactly "$FN" 'secretsmanager:GetSecretValue'
#   api_call_log_assert_no_calls "$FN" 's3:*'

_API_CALL_LOG_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_api_call_log_python() {
	PYTHONPATH="${_API_CALL_LOG_LIB_DIR}${PYTHONPATH:+:$PYTHONPATH}" python3 "$@"
}

api_call_log_endpoint() {
	echo "${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}/_awsl/calls"
}

api_call_log_clear() {
	_api_call_log_python - <<'PY'
from api_call_log_assert import clear_calls
clear_calls()
PY
}

api_call_log_query() {
	# api_call_log_query [workload=…] [service=…] [action=…] [result=…] [since=…]
	local qs="" arg
	for arg in "$@"; do
		if [[ -n "$qs" ]]; then
			qs="${qs}&${arg}"
		else
			qs="$arg"
		fi
	done
	local url
	url="$(api_call_log_endpoint)"
	if [[ -n "$qs" ]]; then
		url="${url}?${qs}"
	fi
	curl -sf "$url"
}

api_call_log_assert_no_calls() {
	local workload="$1"
	local action_pat="$2"
	_api_call_log_python - "$workload" "$action_pat" <<'PY'
import sys
from api_call_log_assert import assert_no_calls

workload, pattern = sys.argv[1], sys.argv[2]
assert_no_calls(workload, pattern)
print(f"OK: workload {workload!r} made no {pattern!r} calls")
PY
}

api_call_log_assert_exactly() {
	# Exact ordered action list for a workload.
	local workload="$1"
	shift
	_api_call_log_python - "$workload" "$@" <<'PY'
import sys
from api_call_log_assert import assert_exactly

workload, expected = sys.argv[1], sys.argv[2:]
assert_exactly(workload, expected)
print(f"OK: workload {workload!r} actions exactly {expected!r}")
PY
}

api_call_log_assert_denied() {
	# api_call_log_assert_denied WORKLOAD ACTION [REASON_SUBSTRING]
	local workload="$1"
	local action="$2"
	local reason_sub="${3:-}"
	_api_call_log_python - "$workload" "$action" "$reason_sub" <<'PY'
import sys
from api_call_log_assert import assert_denied

workload, action, reason_sub = sys.argv[1], sys.argv[2], sys.argv[3]
hit = assert_denied(workload, action, reason_contains=reason_sub or None)
print(
    f"OK: denied {action!r} for {workload!r} reason={hit.get('reason')!r}"
)
PY
}
