#!/usr/bin/env bash
# Lambda trust policy with aws:SourceArn (#378): function ARN → CreateFunction works,
# other ARN → refused.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
ZIP="$ROOT/.awsbox/lambda-trust-sourcearn.zip"

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
if [[ ! "$ACCOUNT" =~ ^[0-9]{12}$ ]]; then
	echo "FAIL: caller account '${ACCOUNT}' is not 12 digits" >&2
	exit 1
fi

MODES=(match other)
cleanup() {
	local m
	for m in "${MODES[@]}"; do
		aws lambda delete-function --function-name "awsbox-srcarn-${m}-${TS}" >/dev/null 2>&1 || true
		aws iam delete-role --role-name "awsbox-srcarn-${m}-${TS}" >/dev/null 2>&1 || true
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

fn_arn() {
	printf 'arn:aws:lambda:%s:%s:function:%s' "$REGION" "$ACCOUNT" "$1"
}

trust() {
	printf '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole","Condition":{"ArnLike":{"aws:SourceArn":"%s"}}}]}' "$1"
}

create_fn() {
	local mode="$1" src_arn="$2" name="awsbox-srcarn-${1}-${TS}"
	aws iam create-role --role-name "$name" --assume-role-policy-document "$(trust "$src_arn")" >/dev/null
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

MATCH_NAME="awsbox-srcarn-match-${TS}"
OTHER_NAME="awsbox-srcarn-other-${TS}"
check_ok "aws:SourceArn = function ARN" match "$(fn_arn "$MATCH_NAME")"
check_refused "aws:SourceArn = other function ARN" other "$(fn_arn "$OTHER_NAME-nope")"

[[ "$fail" == 0 ]] || exit 1
echo "lambda-trust-sourcearn-smoke: PASS"
