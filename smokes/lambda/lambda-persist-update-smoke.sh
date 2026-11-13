#!/usr/bin/env bash
# #713: after LocalEmu recreate with PERSISTENCE=1, UpdateFunctionCode must
# replace a restored function (even when the zip in awslambda-*-tasks was lost)
# and delete-function must clear the leftover.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EMU="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
FN="sw-persist-lambda-${TS}"
ROLE_NAME="sw-persist-lambda-role-${TS}"
VOL="sw-persist-lambda-vol-${TS}"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")
OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/sw-persist-lambda-XXXXXX.yml")"
ZIP1="$(mktemp "${TMPDIR:-/tmp}/sw-persist-lambda-XXXXXX.zip")"
ZIP2="$(mktemp "${TMPDIR:-/tmp}/sw-persist-lambda-XXXXXX.zip")"
OUT="$(mktemp "${TMPDIR:-/tmp}/sw-persist-lambda-XXXXXX.json")"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws_emu() {
	command aws --endpoint-url "$EMU" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 60 "$@"
}

cleanup() {
	aws_emu lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws_emu iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
	rm -f "$ZIP1" "$ZIP2" "$OUT"
	"${COMPOSE[@]}" up -d --force-recreate --no-deps localstack >/dev/null 2>&1 || true
	rm -f "$OVERRIDE"
	docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

make_zip() {
	local path="$1"
	local marker="$2"
	python3 - <<PY
import zipfile
code = b"""exports.handler = async () => ({ marker: "${marker}" });
"""
with zipfile.ZipFile("${path}", "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY
}

wait_ready() {
	local code=""
	for _ in $(seq 1 90); do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$EMU/" || true)"
		[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && return 0
		sleep 2
	done
	echo "FAIL: LocalEmu not ready (${code:-none})" >&2
	return 1
}

wait_state() {
	local want="$1"
	local st=""
	for _ in $(seq 1 90); do
		st="$(aws_emu lambda get-function --function-name "$FN" \
			--query 'Configuration.State' --output text 2>/dev/null || true)"
		[[ "$st" == "$want" ]] && return 0
		# Failed is terminal for pre-update; Active after update.
		[[ "$want" == "ActiveOrFailed" && ( "$st" == "Active" || "$st" == "Failed" ) ]] && return 0
		sleep 2
	done
	echo "FAIL: State=${st:-empty} want=${want}" >&2
	return 1
}

cat >"$OVERRIDE" <<EOF
services:
  localstack:
    environment:
      PERSISTENCE: "1"
    volumes:
      - persist_localemu:/var/lib/localemu
volumes:
  persist_localemu:
    name: ${VOL}
EOF

echo "== #713 PERSISTENCE=1 recreate volume ${VOL} =="
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
wait_ready

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws_emu iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws_emu iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"

make_zip "$ZIP1" "before"
aws_emu lambda create-function \
	--function-name "$FN" \
	--runtime nodejs18.x \
	--role "$ROLE_ARN" \
	--handler index.handler \
	--zip-file "fileb://${ZIP1}" >/dev/null
wait_state Active

aws_emu lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
	"$OUT" >/dev/null
grep -q '"marker": *"before"\|"marker":"before"' "$OUT" || {
	echo "FAIL: pre-recreate invoke: $(cat "$OUT")" >&2
	exit 1
}
echo "OK: invoke before recreate"

# Flush ON_SHUTDOWN save, then recreate (volume keeps /var/lib/localemu).
"${COMPOSE[@]}" -f "$OVERRIDE" stop localstack >/dev/null
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
wait_ready

# Function record must exist; state may be Active (code spool restored) or Failed.
aws_emu lambda get-function --function-name "$FN" \
	--query 'Configuration.FunctionName' --output text | grep -qx "$FN"
wait_state ActiveOrFailed
echo "OK: function present after recreate (State=$(aws_emu lambda get-function --function-name "$FN" --query 'Configuration.State' --output text))"

make_zip "$ZIP2" "after"
# This is the failure mode in #713 without the patch.
aws_emu lambda update-function-code \
	--function-name "$FN" --zip-file "fileb://${ZIP2}" >/dev/null
wait_state Active
echo "OK: UpdateFunctionCode after recreate"

aws_emu lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
	"$OUT" >/dev/null
grep -q '"marker": *"after"\|"marker":"after"' "$OUT" || {
	echo "FAIL: post-update invoke: $(cat "$OUT")" >&2
	exit 1
}
echo "OK: invoke after UpdateFunctionCode"

aws_emu lambda delete-function --function-name "$FN" >/dev/null
if aws_emu lambda get-function --function-name "$FN" >/dev/null 2>&1; then
	echo "FAIL: function still present after delete" >&2
	exit 1
fi
echo "OK: delete-function after restore"

# Recreate same name must succeed (no leftover).
aws_emu lambda create-function \
	--function-name "$FN" \
	--runtime nodejs18.x \
	--role "$ROLE_ARN" \
	--handler index.handler \
	--zip-file "fileb://${ZIP2}" >/dev/null
wait_state Active
echo "OK: recreate same name after delete"

echo "OK: Lambda UpdateFunctionCode survives PERSISTENCE recreate (#713)"
