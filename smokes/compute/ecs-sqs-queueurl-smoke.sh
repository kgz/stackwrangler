#!/usr/bin/env bash
# ECS SendMessage using the QueueUrl from CreateQueue (sqs.<region>.localhost).
# Same --add-host inject as Lambda (#459); bridge task so Docker honours the
# mapping (host networkMode ignores --add-host). SDK v3 uses QueueUrl host
# even when AWS_ENDPOINT_URL is set (#463).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
P="awsbox-ecs-qurl-${TS}"
KEEP="${STACKWRANGLER_AUTHZ_KEEP:-${AWSBOX_AUTHZ_KEEP:-0}}"
TMP="$(mktemp -d)"
IMAGE="awsbox-ecs-qurl:${TS}"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

CLUSTER="" FAMILY="" QURL="" TASK_ARN=""
cleanup() {
	[[ "$KEEP" == "1" ]] && { rm -rf "$TMP"; return 0; }
	[[ -n "$TASK_ARN" && -n "$CLUSTER" ]] && \
		aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
	[[ -n "$CLUSTER" ]] && aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	[[ -n "$QURL" ]] && aws sqs delete-queue --queue-url "$QURL" >/dev/null 2>&1 || true
	docker rmi "$IMAGE" >/dev/null 2>&1 || true
	rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "ok: $*"; }

mkdir -p "$TMP/img"
cat >"$TMP/img/package.json" <<'JSON'
{"name":"ecs-sqs-qurl","private":true,"dependencies":{"@aws-sdk/client-sqs":"3.679.0"}}
JSON
cat >"$TMP/img/send.js" <<'JS'
const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");
(async () => {
  const QueueUrl = process.env.QUEUE_URL;
  const body = process.env.BODY || "ping";
  if (!QueueUrl) {
    console.error("QUEUE_URL missing");
    process.exit(2);
  }
  const client = new SQSClient({});
  await client.send(new SendMessageCommand({ QueueUrl, MessageBody: body }));
  console.log(JSON.stringify({ ok: true, QueueUrl }));
})().catch((err) => {
  console.error(String(err && err.stack ? err.stack : err));
  process.exit(1);
});
JS
cat >"$TMP/img/Dockerfile" <<'EOF'
FROM node:18-alpine
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev --no-fund --no-audit
COPY send.js .
ENTRYPOINT ["node", "/app/send.js"]
EOF

docker build -t "$IMAGE" "$TMP/img" >/dev/null

QURL="$(aws sqs create-queue --queue-name "${P}-q" --query QueueUrl --output text)"
[[ -n "$QURL" && "$QURL" != "None" ]] || fail "CreateQueue returned empty QueueUrl"
case "$QURL" in
	*"sqs.${REGION}."*) ok "CreateQueue QueueUrl uses sqs.${REGION}.* host ($QURL)" ;;
	*) fail "expected standard QueueUrl host sqs.${REGION}.* got: $QURL" ;;
esac

CLUSTER="${P}-cluster"
FAMILY="${P}-family"
BODY="ecs-qurl-${TS}"
# Env keys: in-container 169.254.170.2 DNAT for task-role creds is broken under
# compose (ecs-authz-smoke.sh). QueueUrl host inject is what this smoke asserts.
KEY="${AWS_ACCESS_KEY_ID}"
SECRET="${AWS_SECRET_ACCESS_KEY}"
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

CDEFS="$(
	QUEUE_URL="$QURL" BODY="$BODY" IMAGE="$IMAGE" \
	AWS_ACCESS_KEY_ID="$KEY" AWS_SECRET_ACCESS_KEY="$SECRET" AWS_DEFAULT_REGION="$REGION" \
	python3 -c '
import json, os
print(json.dumps([{
  "name": "sender",
  "image": os.environ["IMAGE"],
  "essential": True,
  "memory": 256,
  "environment": [
    {"name": "QUEUE_URL", "value": os.environ["QUEUE_URL"]},
    {"name": "BODY", "value": os.environ["BODY"]},
    {"name": "AWS_ACCESS_KEY_ID", "value": os.environ["AWS_ACCESS_KEY_ID"]},
    {"name": "AWS_SECRET_ACCESS_KEY", "value": os.environ["AWS_SECRET_ACCESS_KEY"]},
    {"name": "AWS_DEFAULT_REGION", "value": os.environ["AWS_DEFAULT_REGION"]},
  ],
}]))
'
)"

aws ecs register-task-definition \
	--family "$FAMILY" \
	--requires-compatibilities EC2 \
	--network-mode bridge \
	--container-definitions "$CDEFS" \
	>/dev/null

TASK_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] || fail "run-task returned no taskArn"
ok "run-task $TASK_ARN"

STATUS="" EXIT_CODE="" REASON=""
for _ in $(seq 1 90); do
	read -r STATUS EXIT_CODE REASON < <(
		aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --output json \
			| python3 -c '
import json, sys
t = json.load(sys.stdin)["tasks"][0]
c = (t.get("containers") or [{}])[0]
ex = c.get("exitCode")
print(t.get("lastStatus") or "", "" if ex is None else ex, (t.get("stoppedReason") or "").replace("\n", " "))
'
	)
	[[ "$STATUS" == "STOPPED" ]] && break
	sleep 2
done
[[ "$STATUS" == "STOPPED" ]] || fail "task never STOPPED (status=${STATUS})"

LOGS=""
CID="$(docker ps -aq --filter "label=localemu.task-arn=${TASK_ARN}" | head -1 || true)"
[[ -n "$CID" ]] && LOGS="$(docker logs "$CID" 2>&1 || true)"
if [[ "$EXIT_CODE" != "0" ]]; then
	if echo "$LOGS" | grep -qiE 'ENOTFOUND|getaddrinfo'; then
		fail "ECS could not resolve QueueUrl host (exit=${EXIT_CODE}; logs=${LOGS}; reason=${REASON})"
	fi
	fail "sender exit ${EXIT_CODE} (reason=${REASON}; logs=${LOGS})"
fi
if echo "$LOGS" | grep -qiE 'ENOTFOUND|getaddrinfo'; then
	fail "ECS could not resolve QueueUrl host (logs=${LOGS})"
fi
echo "$LOGS" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true' \
	|| fail "sender did not print ok (logs=${LOGS})"

got=""
for _ in $(seq 1 20); do
	got="$(aws sqs receive-message --queue-url "$QURL" --wait-time-seconds 1 \
		--max-number-of-messages 1 --query 'Messages[0].Body' --output text 2>/dev/null || true)"
	[[ "$got" == "$BODY" ]] && break
	sleep 1
done
[[ "$got" == "$BODY" ]] || fail "message never arrived on queue (got='${got}')"
ok "ECS SendMessage via CreateQueue QueueUrl; message received"
