#!/usr/bin/env bash
# #751: PERSISTENCE=1 recreate must restore Lambda versions to Active (code
# bodies intact) — including a larger zip, a published version, and an SQS
# ESM — without EndpointConnectionError to localhost:4566 during startup.
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
P="sw-lam-restore-${TS}"
VOL="sw-lam-restore-vol-${TS}"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")
OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/sw-lam-restore-XXXXXX.yml")"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sw-lam-restore-XXXXXX")"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws_emu() {
	command aws --endpoint-url "$EMU" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 60 "$@"
}

ROLE=""
FNS=()
QURL=""
UUID=""

cleanup() {
	[[ -n "$UUID" ]] && aws_emu lambda delete-event-source-mapping --uuid "$UUID" >/dev/null 2>&1 || true
	for fn in "${FNS[@]:-}"; do
		[[ -n "$fn" ]] && aws_emu lambda delete-function --function-name "$fn" >/dev/null 2>&1 || true
	done
	[[ -n "$QURL" ]] && aws_emu sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
	if [[ -n "$ROLE" ]]; then
		aws_emu iam detach-role-policy --role-name "$ROLE" \
			--policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole >/dev/null 2>&1 || true
		aws_emu iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	fi
	rm -rf "$TMP"
	rm -f "$OVERRIDE"
	"${COMPOSE[@]}" up -d --force-recreate -V --no-deps localstack >/dev/null 2>&1 || true
	docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_ready() {
	local body=""
	for _ in $(seq 1 90); do
		body="$(curl -sf --max-time 2 "$EMU/_localemu/health" 2>/dev/null || true)"
		if [[ "$body" == *'"services"'* ]]; then
			if aws_emu iam list-roles --max-items 1 >/dev/null 2>&1 \
				&& aws_emu lambda list-functions --max-items 1 >/dev/null 2>&1; then
				return 0
			fi
		fi
		sleep 2
	done
	echo "FAIL: LocalEmu not ready (health/IAM/Lambda)" >&2
	return 1
}

wait_state() {
	local fn="$1"
	local want="$2"
	local st=""
	for _ in $(seq 1 90); do
		st="$(aws_emu lambda get-function --function-name "$fn" \
			--query 'Configuration.State' --output text 2>/dev/null || true)"
		[[ "$st" == "$want" ]] && return 0
		sleep 2
	done
	echo "FAIL: $fn State=${st:-empty} want=${want}" >&2
	return 1
}

make_zip() {
	local path="$1"
	local marker="$2"
	local pad_kb="${3:-0}"
	python3 - <<PY
import zipfile
code = b"""exports.handler = async () => ({ marker: "${marker}" });
"""
with zipfile.ZipFile("${path}", "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
    pad = int("${pad_kb}")
    if pad > 0:
        # Inflate archive so restore exercises a larger S3 body (#751).
        z.writestr("pad.bin", b"x" * (pad * 1024))
PY
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

echo "== #751 PERSISTENCE restore (volume ${VOL}) =="
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
wait_ready

ROLE="${P}-role"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws_emu iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws_emu iam attach-role-policy --role-name "$ROLE" \
	--policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole >/dev/null
ROLE_ARN="$(aws_emu iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

# Several small functions + one larger zip (Serverless-ish) with published ver + ESM.
for i in 1 2 3 4 5; do
	fn="${P}-fn${i}"
	FNS+=("$fn")
	make_zip "$TMP/${fn}.zip" "fn${i}" 0
	aws_emu lambda create-function \
		--function-name "$fn" \
		--runtime nodejs18.x \
		--role "$ROLE_ARN" \
		--handler index.handler \
		--zip-file "fileb://${TMP}/${fn}.zip" >/dev/null
	wait_state "$fn" Active
done

BIG="${P}-big"
FNS+=("$BIG")
make_zip "$TMP/${BIG}.zip" "big" 512
aws_emu lambda create-function \
	--function-name "$BIG" \
	--runtime nodejs18.x \
	--role "$ROLE_ARN" \
	--handler index.handler \
	--zip-file "fileb://${TMP}/${BIG}.zip" >/dev/null
wait_state "$BIG" Active
aws_emu lambda publish-version --function-name "$BIG" >/dev/null

QURL="$(aws_emu sqs create-queue --queue-name "${P}-q" --query 'QueueUrl' --output text)"
QARN="$(aws_emu sqs get-queue-attributes --queue-url "$QURL" \
	--attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
UUID="$(aws_emu lambda create-event-source-mapping \
	--function-name "$BIG" \
	--event-source-arn "$QARN" \
	--batch-size 1 \
	--query 'UUID' --output text)"

OUT="$TMP/out.json"
for fn in "${FNS[@]}"; do
	aws_emu lambda invoke --function-name "$fn" --cli-binary-format raw-in-base64-out \
		"$OUT" >/dev/null
done
echo "OK: ${#FNS[@]} functions Active (+ published version + ESM) before recreate"

# Flush ON_SHUTDOWN save, recreate container, keep s3_bodies (happy path).
"${COMPOSE[@]}" -f "$OVERRIDE" stop localstack >/dev/null
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
wait_ready

for fn in "${FNS[@]}"; do
	wait_state "$fn" Active
	aws_emu lambda get-function --function-name "$fn" \
		--query 'Configuration.StateReason' --output text 2>/dev/null \
		| grep -qi 'EndpointConnection\|localhost:4566' && {
		echo "FAIL: $fn StateReason mentions gateway connection error" >&2
		exit 1
	}
	aws_emu lambda invoke --function-name "$fn" --cli-binary-format raw-in-base64-out \
		"$OUT" >/dev/null
done

# Published :1 must also be Active (issue saw $LATEST and :1 both Failed).
PUB_STATE="$(aws_emu lambda get-function --function-name "${BIG}:1" \
	--query 'Configuration.State' --output text 2>/dev/null || true)"
[[ "$PUB_STATE" == "Active" ]] || {
	echo "FAIL: ${BIG}:1 State=${PUB_STATE:-empty} want=Active" >&2
	exit 1
}

aws_emu lambda invoke --function-name "$BIG" --cli-binary-format raw-in-base64-out \
	"$OUT" >/dev/null
grep -q '"marker": *"big"\|"marker":"big"' "$OUT" || {
	echo "FAIL: post-restore invoke: $(cat "$OUT")" >&2
	exit 1
}

echo "OK: Lambda persist restore keeps Active + invoke after recreate (#751)"
