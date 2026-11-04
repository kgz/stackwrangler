#!/usr/bin/env bash
# Lambda trust policy with aws:SourceAccount (#374): same account → CreateFunction works,
# other account → refused, plain trust still works.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
ZIP="$ROOT/.awsbox/lambda-trust-condition.zip"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
# Same account with the last digit bumped: never the caller's, whatever AWSBOX_ACCOUNT_IDS maps.
OTHER_ACCOUNT="${ACCOUNT:0:11}$(((${ACCOUNT:11:1} + 1) % 10))"
if [[ ! "$ACCOUNT" =~ ^[0-9]{12}$ || "$OTHER_ACCOUNT" == "$ACCOUNT" ]]; then
	echo "FAIL: cannot derive a distinct account from caller account '${ACCOUNT}'" >&2
	exit 1
fi

MODES=(plain same other)
cleanup() {
	local m
	for m in "${MODES[@]}"; do
		aws lambda delete-function --function-name "awsbox-trust-${m}-${TS}" >/dev/null 2>&1 || true
		aws iam delete-role --role-name "awsbox-trust-${m}-${TS}" >/dev/null 2>&1 || true
	done
	rm -f "$ZIP"
}
trap cleanup EXIT

mkdir -p "$ROOT/.awsbox"
python3 - <<'PY' "$ZIP"
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", "exports.handler = async () => ({ ok: true });\n")
PY

trust() {
	local cond=""
	[[ -n "${1:-}" ]] && cond=",\"Condition\":{\"StringEquals\":{\"aws:SourceAccount\":\"$1\"}}"
	printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"%s}]}' "$cond"
}

# create_fn <mode> <source-account|""> → exit status of create-function
create_fn() {
	local mode="$1" src="$2" name="awsbox-trust-${1}-${TS}"
	aws iam create-role --role-name "$name" --assume-role-policy-document "$(trust "$src")" >/dev/null
	aws lambda create-function --function-name "$name" --runtime nodejs20.x \
		--handler index.handler --role "arn:aws:iam::${ACCOUNT}:role/${name}" \
		--zip-file "fileb://${ZIP}" 2>&1
}

fail=0
check_ok() {
	local label="$1" mode="$2" src="$3" out
	if out="$(create_fn "$mode" "$src")"; then
		echo "ok: ${label}"
	else
		echo "FAIL: ${label} was refused: ${out}" >&2
		fail=1
	fi
}
check_refused() {
	local label="$1" mode="$2" src="$3" out
	if out="$(create_fn "$mode" "$src")"; then
		echo "FAIL: ${label} was accepted" >&2
		fail=1
	elif [[ "$out" == *"cannot be assumed by Lambda"* ]]; then
		echo "ok: ${label}"
	else
		echo "FAIL: ${label} failed with unexpected error: ${out}" >&2
		fail=1
	fi
}

check_ok "plain trust (no condition)" plain ""
check_ok "aws:SourceAccount = function account" same "$ACCOUNT"
check_refused "aws:SourceAccount = other account" other "$OTHER_ACCOUNT"

[[ "$fail" == 0 ]] || exit 1
echo "lambda-trust-condition-smoke: PASS"
