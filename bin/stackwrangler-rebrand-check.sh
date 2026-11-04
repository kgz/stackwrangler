#!/usr/bin/env bash
# Unit check for #305 rebrand: awsbox shim + AWSBOX_* env fallback (no Docker).
# Usage: ./bin/stackwrangler-rebrand-check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

pass() {
	echo "ok: $*"
}

# --- shim: one stderr line naming stackwrangler, then stackwrangler usage ---
shim_err="$(mktemp)"
shim_out="$(mktemp)"
set +e
./bin/awsbox >"$shim_out" 2>"$shim_err"
shim_ec=$?
set -e
sw_err="$(mktemp)"
set +e
./bin/stackwrangler >"/dev/null" 2>"$sw_err"
sw_ec=$?
set -e

mapfile -t shim_lines <"$shim_err"
[[ ${#shim_lines[@]} -ge 1 ]] || fail "awsbox produced no stderr"
[[ "${shim_lines[0]}" == *stackwrangler* ]] || fail "first stderr line must name stackwrangler (got: ${shim_lines[0]})"
[[ "$(wc -l <"$shim_out" | tr -d ' ')" == "0" ]] || fail "awsbox should not print the rename notice on stdout"
[[ "$shim_ec" -eq "$sw_ec" ]] || fail "awsbox exit $shim_ec != stackwrangler exit $sw_ec"
# exec resets $0 to an absolute path; still must be stackwrangler usage
shim_usage="$(tail -n +2 "$shim_err")"
[[ "$shim_usage" == Usage:*stackwrangler* ]] \
	|| fail "awsbox did not exec stackwrangler usage (got: ${shim_usage})"
[[ "$(cat "$sw_err")" == Usage:*stackwrangler* ]] \
	|| fail "stackwrangler usage missing product name"
pass "awsbox shim stderr + exec/delegate"

# --- AWSBOX-only .env → profile keys (no STACKWRANGLER_*) ---
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$shim_err" "$shim_out" "$sw_err"' EXIT

# Isolate profile writes from the developer's ~/.aws
export AWS_SHARED_CREDENTIALS_FILE="$WORK/credentials"
export AWS_CONFIG_FILE="$WORK/config"
# Isolate product .env without touching the worktree copy permanently
ENV_BAK=""
if [[ -f "$ROOT/.env" ]]; then
	ENV_BAK="$WORK/env.bak"
	cp "$ROOT/.env" "$ENV_BAK"
fi
restore_env() {
	if [[ -n "$ENV_BAK" ]]; then
		cp "$ENV_BAK" "$ROOT/.env"
	else
		rm -f "$ROOT/.env"
	fi
}
trap 'restore_env; rm -rf "$WORK" "$shim_err" "$shim_out" "$sw_err"' EXIT

cat >"$ROOT/.env" <<'EOF'
AWSBOX_ACCESS_KEY=onlyawsbox
AWSBOX_SECRET_KEY=onlyawsboxsecret
AWSBOX_REGION=eu-west-1
AWSBOX_ENDPOINT=http://127.0.0.1:8333
AWSBOX_IAM_ENDPOINT=http://127.0.0.1:4566
EOF
# Ensure STACKWRANGLER_* are unset in this process
unset STACKWRANGLER_ACCESS_KEY STACKWRANGLER_SECRET_KEY STACKWRANGLER_REGION \
	STACKWRANGLER_ENDPOINT STACKWRANGLER_IAM_ENDPOINT || true

./bin/stackwrangler-profile write --force >/dev/null

grep -q '^aws_access_key_id = onlyawsbox$' "$AWS_SHARED_CREDENTIALS_FILE" \
	|| fail "profile access key not resolved from AWSBOX_*"
grep -q '^aws_secret_access_key = onlyawsboxsecret$' "$AWS_SHARED_CREDENTIALS_FILE" \
	|| fail "profile secret not resolved from AWSBOX_*"
grep -q '^# stackwrangler-managed$' "$AWS_SHARED_CREDENTIALS_FILE" \
	|| fail "profile marker should be stackwrangler-managed"
grep -q '^services = stackwrangler$' "$AWS_CONFIG_FILE" \
	|| fail "AWS config services label should be stackwrangler"
grep -q '^region = eu-west-1$' "$AWS_CONFIG_FILE" \
	|| fail "profile region not resolved from AWSBOX_*"
pass "AWSBOX-only .env drives profile keys + stackwrangler services label"

# STACKWRANGLER_* wins when both are set
cat >"$ROOT/.env" <<'EOF'
STACKWRANGLER_ACCESS_KEY=newkey
AWSBOX_ACCESS_KEY=onlyawsbox
STACKWRANGLER_SECRET_KEY=newsecret
AWSBOX_SECRET_KEY=onlyawsboxsecret
STACKWRANGLER_REGION=us-east-1
AWSBOX_REGION=eu-west-1
STACKWRANGLER_ENDPOINT=http://127.0.0.1:8333
STACKWRANGLER_IAM_ENDPOINT=http://127.0.0.1:4566
EOF
./bin/stackwrangler-profile write --force >/dev/null
grep -q '^aws_access_key_id = newkey$' "$AWS_SHARED_CREDENTIALS_FILE" \
	|| fail "STACKWRANGLER_* should win over AWSBOX_*"
grep -qv 'onlyawsbox' "$AWS_SHARED_CREDENTIALS_FILE" \
	|| fail "legacy AWSBOX key should not remain when STACKWRANGLER is set"
pass "STACKWRANGLER_* wins over AWSBOX_*"


# --- smoke helper: STACKWRANGLER_* → AWSBOX_* → stackwrangler defaults ---
unset STACKWRANGLER_ACCESS_KEY STACKWRANGLER_SECRET_KEY STACKWRANGLER_REGION \
	STACKWRANGLER_ENDPOINT STACKWRANGLER_IAM_ENDPOINT \
	AWSBOX_ACCESS_KEY AWSBOX_SECRET_KEY AWSBOX_REGION \
	AWSBOX_ENDPOINT AWSBOX_IAM_ENDPOINT || true
rm -f "$ROOT/.env"
# shellcheck disable=SC1091
source "$ROOT/bin/stackwrangler-env.sh"
[[ "$STACKWRANGLER_ACCESS_KEY" == "stackwrangler" ]] \
	|| fail "helper default access key (got: $STACKWRANGLER_ACCESS_KEY)"
[[ "$STACKWRANGLER_SECRET_KEY" == "stackwranglerstackwrangler" ]] \
	|| fail "helper default secret"
[[ "$AWSBOX_ACCESS_KEY" == "stackwrangler" ]] \
	|| fail "helper should mirror defaults onto AWSBOX_*"
pass "stackwrangler-env.sh defaults without .env"

cat >"$ROOT/.env" <<'EOF'
AWSBOX_ACCESS_KEY=onlyawsbox
AWSBOX_SECRET_KEY=onlyawsboxsecret
EOF
unset STACKWRANGLER_ACCESS_KEY STACKWRANGLER_SECRET_KEY \
	AWSBOX_ACCESS_KEY AWSBOX_SECRET_KEY || true
# shellcheck disable=SC1091
source "$ROOT/bin/stackwrangler-env.sh"
[[ "$STACKWRANGLER_ACCESS_KEY" == "onlyawsbox" ]] \
	|| fail "helper should fall back to AWSBOX_* from .env"
pass "stackwrangler-env.sh falls back to AWSBOX_*"

echo "stackwrangler-rebrand-check: all ok"
