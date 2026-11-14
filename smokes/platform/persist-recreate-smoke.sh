#!/usr/bin/env bash
# #200: PERSISTENCE=1 recreate keeps S3 + IAM + Secrets + SSM + DDB + Lambda invoke.
# Uses a unique state volume (does not flip host --dev mode). RDS behaviour is
# documented in docs/dev-mode.md; host-port survive covered by #705 smoke.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EMU="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
SUFFIX="sw-persist-${TS}"
VOL="sw-persist-multi-vol-${TS}"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")
OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/sw-persist-multi-XXXXXX.yml")"
ZIP="$(mktemp "${TMPDIR:-/tmp}/sw-persist-multi-XXXXXX.zip")"
OUT="$(mktemp "${TMPDIR:-/tmp}/sw-persist-multi-XXXXXX.out")"

BUCKET="${SUFFIX}-bkt"
ROLE_NAME="${SUFFIX}-role"
SECRET_NAME="${SUFFIX}-secret"
SSM_NAME="/${SUFFIX}/param"
TABLE="${SUFFIX}-ddb"
FN="${SUFFIX}-fn"
MARKER="persist-${TS}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	aws --endpoint-url "$EMU" --region "$REGION" s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	aws --endpoint-url "$EMU" --region "$REGION" lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws --endpoint-url "$EMU" --region "$REGION" dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
	aws --endpoint-url "$EMU" --region "$REGION" secretsmanager delete-secret --secret-id "$SECRET_NAME" --force-delete-without-recovery >/dev/null 2>&1 || true
	aws --endpoint-url "$EMU" --region "$REGION" ssm delete-parameter --name "$SSM_NAME" >/dev/null 2>&1 || true
	aws --endpoint-url "$EMU" --region "$REGION" iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
	"${COMPOSE[@]}" up -d --force-recreate --no-deps localstack >/dev/null 2>&1 || true
	rm -f "$OVERRIDE" "$ZIP" "$OUT"
	docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

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

echo "== persistence override (volume ${VOL}) =="
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null

wait_ready() {
	local code=""
	for _ in $(seq 1 90); do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$EMU/" || true)"
		[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && return 0
		sleep 2
	done
	fail "LocalEmu not ready (${code:-none})"
}

wait_lambda_active() {
	local state=""
	for _ in $(seq 1 60); do
		state="$(aws_emu lambda get-function --function-name "$FN" --query 'Configuration.State' --output text 2>/dev/null || true)"
		[[ "$state" == "Active" ]] && return 0
		sleep 2
	done
	fail "Lambda not Active (state=${state:-none})"
}

aws_emu() { command aws --endpoint-url "$EMU" --region "$REGION" "$@"; }

make_zip() {
	python3 - "$ZIP" "$MARKER" <<'PY'
import sys, zipfile
path, marker = sys.argv[1], sys.argv[2]
src = (
	"exports.handler = async () => ({ statusCode: 200, body: JSON.stringify({ marker: %r }) });\n"
	% marker
)
with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
	z.writestr("index.js", src)
PY
}

wait_ready

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

echo "== seed S3 + IAM + Secrets + SSM + DDB + Lambda =="
aws_emu s3 mb "s3://${BUCKET}" >/dev/null
printf '%s' "$MARKER" | aws_emu s3 cp - "s3://${BUCKET}/obj" >/dev/null

aws_emu iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws_emu iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"

aws_emu secretsmanager create-secret --name "$SECRET_NAME" --secret-string "{\"v\":\"${MARKER}\"}" >/dev/null
aws_emu ssm put-parameter --name "$SSM_NAME" --type String --value "$MARKER" >/dev/null

aws_emu dynamodb create-table \
	--table-name "$TABLE" \
	--attribute-definitions AttributeName=pk,AttributeType=S \
	--key-schema AttributeName=pk,KeyType=HASH \
	--billing-mode PAY_PER_REQUEST >/dev/null
for _ in $(seq 1 30); do
	st="$(aws_emu dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text 2>/dev/null || true)"
	[[ "$st" == "ACTIVE" ]] && break
	sleep 1
done
aws_emu dynamodb put-item \
	--table-name "$TABLE" \
	--item "{\"pk\":{\"S\":\"row1\"},\"v\":{\"S\":\"${MARKER}\"}}" >/dev/null

make_zip
aws_emu lambda create-function \
	--function-name "$FN" \
	--runtime nodejs18.x \
	--role "$ROLE_ARN" \
	--handler index.handler \
	--zip-file "fileb://${ZIP}" >/dev/null
wait_lambda_active
aws_emu lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out "$OUT" >/dev/null
grep -q "$MARKER" "$OUT" || fail "pre-recreate invoke missing marker: $(cat "$OUT")"

echo "== recreate LocalEmu (PERSISTENCE volume kept) =="
"${COMPOSE[@]}" -f "$OVERRIDE" stop localstack >/dev/null
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
wait_ready

echo "== assert restored =="
got="$(aws_emu s3 cp "s3://${BUCKET}/obj" -)" || fail "S3 object missing after recreate"
[[ "$got" == "$MARKER" ]] || fail "S3 body mismatch (got=${got})"

aws_emu iam get-role --role-name "$ROLE_NAME" >/dev/null || fail "IAM role missing after recreate"

sec="$(aws_emu secretsmanager get-secret-value --secret-id "$SECRET_NAME" --query 'SecretString' --output text)" || fail "secret missing"
echo "$sec" | grep -q "$MARKER" || fail "secret value mismatch (${sec})"

ssm="$(aws_emu ssm get-parameter --name "$SSM_NAME" --query 'Parameter.Value' --output text)" || fail "SSM missing"
[[ "$ssm" == "$MARKER" ]] || fail "SSM value mismatch (${ssm})"

item="$(aws_emu dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"row1"}}' --query 'Item.v.S' --output text)" || fail "DDB item missing"
[[ "$item" == "$MARKER" ]] || fail "DDB value mismatch (${item})"

wait_lambda_active
aws_emu lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out "$OUT" >/dev/null
grep -q "$MARKER" "$OUT" || fail "Lambda invoke after recreate missing marker: $(cat "$OUT")"

echo "OK: persist-recreate S3+IAM+Secrets+SSM+DDB+Lambda (#200)"
