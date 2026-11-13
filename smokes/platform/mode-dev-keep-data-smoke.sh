#!/usr/bin/env bash
# #288: up --dev → durable state → down → up --dev keeps data; reset empties markers.
# Requires LocalEmu. Caller: ./bin/batch-resource-gate.sh check --need-up first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

SEA="${STACKWRANGLER_ENDPOINT:-${AWSBOX_ENDPOINT:-http://127.0.0.1:8333}}"
EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
BUCKET="sw-dev-keep-${TS}"
ROLE_NAME="sw-dev-keep-role-${TS}"
MARKER_OBJ="keep-data.txt"
MARKER_BODY="dev-keep-${TS}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

aws_sea() {
	command aws --endpoint-url "$SEA" --region "$REGION" "$@"
}

aws_emu() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	"$ROOT/bin/stackwrangler" down >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> up --dev"
"$ROOT/bin/stackwrangler" up --dev

echo "==> seed Seaweed object + IAM role"
aws_sea s3 mb "s3://${BUCKET}" >/dev/null
printf '%s' "$MARKER_BODY" | aws_sea s3 cp - "s3://${BUCKET}/${MARKER_OBJ}" >/dev/null
aws_emu iam create-role \
	--role-name "$ROLE_NAME" \
	--assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
	>/dev/null

got="$(aws_sea s3 cp "s3://${BUCKET}/${MARKER_OBJ}" -)"
[[ "$got" == "$MARKER_BODY" ]] || fail "seed object mismatch (got ${got})"
aws_emu iam get-role --role-name "$ROLE_NAME" >/dev/null || fail "seed role missing"

echo "==> down (keep state)"
"$ROOT/bin/stackwrangler" down

[[ -d "$ROOT/.awsbox/dev/localemu" ]] || fail "down removed .awsbox/dev/localemu"
mode="$(tr -d '[:space:]' <"$ROOT/.awsbox/mode")"
[[ "$mode" == "dev" ]] || fail "down changed mode (got ${mode})"

echo "==> up --dev again"
"$ROOT/bin/stackwrangler" up --dev

echo "==> assert kept"
got="$(aws_sea s3 cp "s3://${BUCKET}/${MARKER_OBJ}" -)" || fail "Seaweed object missing after down/up"
[[ "$got" == "$MARKER_BODY" ]] || fail "Seaweed object changed after down/up (got ${got})"
aws_emu iam get-role --role-name "$ROLE_NAME" >/dev/null || fail "IAM role missing after down/up"

echo "==> reset empties intentional wipe paths"
"$ROOT/bin/stackwrangler" reset
[[ ! -e "$ROOT/.awsbox/dev/localemu" ]] || fail "reset left .awsbox/dev/localemu"
mode="$(tr -d '[:space:]' <"$ROOT/.awsbox/mode")"
[[ "$mode" == "test" ]] || fail "reset should set mode=test (got ${mode})"

# Seaweed/IAM emptiness after reset depends on volume removal; best-effort check.
if aws_sea s3 ls "s3://${BUCKET}/${MARKER_OBJ}" >/dev/null 2>&1; then
	fail "Seaweed object still present after reset"
fi

echo "OK mode-dev-keep-data-smoke"
