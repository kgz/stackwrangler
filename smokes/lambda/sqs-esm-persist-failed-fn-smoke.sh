#!/usr/bin/env bash
# PERSISTENCE=1: a function whose code fails to restore keeps its SQS ESM;
# the poller starts once the code is updated, and the mapping survives later restarts (#836).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EMU="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
P="sw-esm-failfn-${TS}"
VOL="sw-esm-failfn-vol-${TS}"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")
OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/sw-esm-failfn-XXXXXX.yml")"
TMP="$(mktemp -d)"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws_emu() { command aws --endpoint-url "$EMU" --region "$REGION" "$@"; }

QURL=""
ROLE=""
FN=""
UUID=""

cleanup() {
	[[ -n "$UUID" ]] && aws_emu lambda delete-event-source-mapping --uuid "$UUID" >/dev/null 2>&1 || true
	[[ -n "$FN" ]] && aws_emu lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	[[ -n "$QURL" ]] && aws_emu sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
	if [[ -n "$ROLE" ]]; then
		aws_emu iam detach-role-policy --role-name "$ROLE" \
			--policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole >/dev/null 2>&1 || true
		aws_emu iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	fi
	rm -rf "$TMP"
	"${COMPOSE[@]}" up -d --force-recreate --no-deps localstack >/dev/null 2>&1 || true
	rm -f "$OVERRIDE"
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
	# Prefer /_localemu/health (any HTTP on / can race mid-recreate).
	local body=""
	for _ in $(seq 1 90); do
		body="$(curl -sf --max-time 2 "$EMU/_localemu/health" 2>/dev/null || true)"
		if [[ "$body" == *'"services"'* ]]; then
			# Signed call must also succeed — health alone can precede IAM.
			if aws_emu iam list-roles --max-items 1 >/dev/null 2>&1; then
				return 0
			fi
		fi
		sleep 2
	done
	echo "FAIL: LocalEmu not ready (health/IAM)" >&2
	return 1
}
wait_ready

ROLE="${P}-role"
FN="${P}-fn"
QNAME="${P}-q"

cat >"$TMP/trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat >"$TMP/index.py" <<'EOF'
def handler(event, context):
    return 1
EOF
(cd "$TMP" && zip -q fn.zip index.py)

aws_emu iam create-role --role-name "$ROLE" --assume-role-policy-document "file://$TMP/trust.json" >/dev/null
aws_emu iam attach-role-policy --role-name "$ROLE" \
	--policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole >/dev/null
ROLE_ARN="$(aws_emu iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

QURL="$(aws_emu sqs create-queue --queue-name "$QNAME" --query 'QueueUrl' --output text)"
QARN="$(aws_emu sqs get-queue-attributes --queue-url "$QURL" --attribute-names QueueArn \
	--query 'Attributes.QueueArn' --output text)"

aws_emu lambda create-function \
	--function-name "$FN" \
	--runtime python3.12 \
	--handler index.handler \
	--role "$ROLE_ARN" \
	--zip-file "fileb://$TMP/fn.zip" \
	--timeout 10 >/dev/null

for _ in $(seq 1 30); do
	st="$(aws_emu lambda get-function --function-name "$FN" --query 'Configuration.State' --output text 2>/dev/null || true)"
	[[ "$st" == "Active" ]] && break
	sleep 1
done

UUID="$(aws_emu lambda create-event-source-mapping \
	--function-name "$FN" \
	--event-source-arn "$QARN" \
	--batch-size 1 \
	--query 'UUID' --output text)"
echo "created ESM uuid=$UUID"


count_listed() {
	aws_emu lambda list-event-source-mappings --query "length(EventSourceMappings[?UUID=='$UUID'])" --output text 2>/dev/null || echo 0
}

restart_saved() {
	"${COMPOSE[@]}" -f "$OVERRIDE" stop localstack >/dev/null
	[[ "${1:-}" == "empty-code" ]] && docker run --rm -v "${VOL}:/v" alpine:3.20 \
		sh -c 'find /v/state/state/assets/s3_bodies -name "*.body" -exec sh -c ": > \"\$1\"" _ {} \;'
	"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
	wait_ready
	sleep 20 # deferred Lambda/ESM restore + sweep
}

echo "== restart with the function's code body emptied =="
restart_saved empty-code
st="$(aws_emu lambda get-function --function-name "$FN" --query 'Configuration.State' --output text 2>/dev/null || true)"
[[ "$st" == "Failed" ]] || { echo "FAIL: expected function Failed after emptied code, got '$st'" >&2; exit 1; }
[[ "$(count_listed)" == "1" ]] || { echo "FAIL: ESM dropped while its function exists (Failed)" >&2; exit 1; }
echo "OK: function Failed, ESM kept"

echo "== update code -> poller starts =="
aws_emu lambda update-function-code --function-name "$FN" --zip-file "fileb://$TMP/fn.zip" >/dev/null
for _ in $(seq 1 30); do
	st="$(aws_emu lambda get-function --function-name "$FN" --query 'Configuration.State' --output text 2>/dev/null || true)"
	[[ "$st" == "Active" ]] && break
	sleep 1
done
[[ "$st" == "Active" ]] || { echo "FAIL: function not Active after update ($st)" >&2; exit 1; }
aws_emu sqs send-message --queue-url "$QURL" --message-body ping >/dev/null
left=""
for _ in $(seq 1 30); do
	left="$(aws_emu sqs get-queue-attributes --queue-url "$QURL" \
		--attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
		--query 'sum([to_number(Attributes.ApproximateNumberOfMessages),to_number(Attributes.ApproximateNumberOfMessagesNotVisible)])' --output text)"
	[[ "$left" == "0" ]] && break
	sleep 2
done
[[ "$left" == "0" ]] || { echo "FAIL: message not consumed after code update (left=$left)" >&2; exit 1; }
echo "OK: kept ESM delivered a message after the code update"

echo "== plain restart -> mapping still there =="
restart_saved
[[ "$(count_listed)" == "1" ]] || { echo "FAIL: ESM lost on a clean restart" >&2; exit 1; }
echo "OK: ESM survives a clean restart"

echo "OK: SQS ESM kept across failed function restore (#836)"
