# shellcheck shell=bash
# Assertion helpers for the LocalEmu API call log (#194).
# Source after local-emu-env.sh (needs AWSBOX_IAM_ENDPOINT).
#
# Usage:
#   source "$ROOT/smokes/lib/api-call-log.sh"
#   api_call_log_clear
#   # … invoke workload …
#   api_call_log_assert_exactly "$FN" 'secretsmanager:GetSecretValue'
#   api_call_log_assert_no_calls "$FN" 's3:*'

api_call_log_endpoint() {
	echo "${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}/_awsl/calls"
}

api_call_log_clear() {
	curl -sf -X DELETE "$(api_call_log_endpoint)" >/dev/null
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
	python3 - "$workload" "$action_pat" "$(api_call_log_endpoint)" <<'PY'
import json, sys, urllib.parse, urllib.request, fnmatch
workload, pattern, base = sys.argv[1], sys.argv[2], sys.argv[3]
url = base + "?" + urllib.parse.urlencode({"workload": workload})
with urllib.request.urlopen(url, timeout=10) as resp:
    data = json.load(resp)
hits = [c for c in data.get("calls", []) if fnmatch.fnmatch(c.get("action", ""), pattern)]
if hits:
    sample = ", ".join(c["action"] for c in hits[:5])
    raise SystemExit(
        f"FAIL: workload {workload!r} made {len(hits)} call(s) matching {pattern!r}: {sample}"
    )
print(f"OK: workload {workload!r} made no {pattern!r} calls")
PY
}

api_call_log_assert_exactly() {
	# Exact ordered action list for a workload (newest-first from API → reverse to chrono).
	local workload="$1"
	shift
	python3 - "$workload" "$(api_call_log_endpoint)" "$@" <<'PY'
import json, sys, urllib.parse, urllib.request
workload, base, expected = sys.argv[1], sys.argv[2], sys.argv[3:]
url = base + "?" + urllib.parse.urlencode({"workload": workload, "limit": "10000"})
with urllib.request.urlopen(url, timeout=10) as resp:
    data = json.load(resp)
# API returns newest-first
got = list(reversed([c.get("action", "") for c in data.get("calls", [])]))
if got != expected:
    raise SystemExit(f"FAIL: workload {workload!r} actions {got!r} != {expected!r}")
print(f"OK: workload {workload!r} actions exactly {expected!r}")
PY
}

api_call_log_assert_denied() {
	local workload="$1"
	local action="$2"
	python3 - "$workload" "$action" "$(api_call_log_endpoint)" <<'PY'
import json, sys, urllib.parse, urllib.request
workload, action, base = sys.argv[1], sys.argv[2], sys.argv[3]
url = base + "?" + urllib.parse.urlencode(
    {"workload": workload, "action": action, "result": "denied"}
)
with urllib.request.urlopen(url, timeout=10) as resp:
    data = json.load(resp)
hits = data.get("calls", [])
if not hits:
    raise SystemExit(f"FAIL: no denied {action!r} for workload {workload!r}")
reason = hits[0].get("reason") or ""
if not reason:
    raise SystemExit(f"FAIL: denied {action!r} missing reason/policy for {workload!r}")
print(f"OK: denied {action!r} for {workload!r} reason={reason!r}")
PY
}
