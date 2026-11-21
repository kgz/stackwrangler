#!/usr/bin/env bash
# #749: up's S3 write probe must sign with the .env keys, and say "key mismatch" (not "disk full")
# when Seaweed rejects them. Offline: stub `aws` on PATH, no LocalEmu / Seaweed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# cmd_up must export .env in the main shell before wait_healthy (endpoint_url only loads it in a subshell).
body="$(sed -n '/^cmd_up()/,/^}/p' "$ROOT/bin/stackwrangler" | grep -v '^[[:space:]]*#')"
load_line="$(echo "$body" | grep -n 'load_root_env' | head -1 | cut -d: -f1)"
wait_line="$(echo "$body" | grep -n 'wait_healthy' | head -1 | cut -d: -f1)"
[[ -n "$load_line" && -n "$wait_line" && "$load_line" -lt "$wait_line" ]] ||
	fail "cmd_up calls wait_healthy before load_root_env"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Stub aws: accepts only key 'custom-key', like Seaweed started from a .env with that key.
cat >"$tmp/aws" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null 2>&1 || true
[[ "${AWS_ACCESS_KEY_ID:-}" == "custom-key" ]] && exit 0
echo "An error occurred (InvalidAccessKeyId) when calling the CreateBucket operation" >&2
exit 1
EOF
chmod +x "$tmp/aws"

probe() { # env assignments… → runs wait_s3_writable in a clean subshell, prints its stderr
	# SKIP_DOTENV: apply product defaults without sourcing repo .env (env -i must win).
	env -i PATH="$tmp:$PATH" HOME="$tmp" STACKWRANGLER_ENV_SKIP_DOTENV=1 "$@" bash -c '
		set -euo pipefail
		source "$0/bin/stackwrangler-env.sh"
		COMPOSE=(true)
		source "$0/bin/stackwrangler-wait-healthy.sh"
		wait_s3_writable http://127.0.0.1:1
	' "$ROOT" 2>&1
}

probe STACKWRANGLER_ACCESS_KEY=custom-key STACKWRANGLER_SECRET_KEY=custom-secret >/dev/null ||
	fail "probe failed with the matching exported key"

start=$SECONDS
out="$(probe || true)"
echo "$out" | grep -q "rejected access key 'stackwrangler'" || fail "key mismatch not reported: $out"
echo "$out" | grep -q 'disk full' && fail "key mismatch reported as disk full"
((SECONDS - start < 10)) || fail "key mismatch should fail fast, took $((SECONDS - start))s"

echo "ok up-env-keys"
