#!/usr/bin/env bash
# Deploy examples/serverless-v4-sns-sqs (topic + consumer) via aws-redirect
# (DNS + TLS → LocalEmu). No AWS_ENDPOINT_URL on the Serverless path (#464).
#
# DNS log asserts AWS names → proxy IP only. We do not prove "only the
# Serverless licence host left the machine" (would need packet capture);
# non-AWS names resolve upstream by design.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/serverless-v4-sns-sqs"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# Maintainer shell may export SERVERLESS_LOCAL_ONLY_LICENCE_KEY only.
if [[ -z "${SERVERLESS_LICENSE_KEY:-}" && -n "${SERVERLESS_LOCAL_ONLY_LICENCE_KEY:-}" ]]; then
	export SERVERLESS_LICENSE_KEY="$SERVERLESS_LOCAL_ONLY_LICENCE_KEY"
fi
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-awsbox}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-awsboxawsbox}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
STAGE="local"
DEPLOY_BUCKET="awsbox-sls4-deploy-${TS}"
[[ -n "${AWSBOX_SLS4_DEPLOY_BUCKET_OVERRIDE:-}" ]] && DEPLOY_BUCKET="$AWSBOX_SLS4_DEPLOY_BUCKET_OVERRIDE"
SUFFIX="${TS}"
TOPIC_SERVICE="awsbox-sls4-topic-${TS}"
CONSUMER_SERVICE="awsbox-sls4-consumer-${TS}"
[[ -n "${AWSBOX_SLS4_TOPIC_SERVICE_OVERRIDE:-}" ]] && TOPIC_SERVICE="$AWSBOX_SLS4_TOPIC_SERVICE_OVERRIDE"
[[ -n "${AWSBOX_SLS4_CONSUMER_SERVICE_OVERRIDE:-}" ]] && CONSUMER_SERVICE="$AWSBOX_SLS4_CONSUMER_SERVICE_OVERRIDE"
TOPIC_STACK="${TOPIC_SERVICE}-${STAGE}"
CONSUMER_STACK="${CONSUMER_SERVICE}-${STAGE}"
TOPIC_EXPORT="${TOPIC_SERVICE}-${STAGE}-TopicArn"
KEEP="${AWSBOX_SLS_V4_KEEP:-0}"
OUT="$ROOT/.awsbox/serverless-v4-${TS}"
REMOVED=0
TOPIC_DEPLOYED=0
CONSUMER_DEPLOYED=0
BUCKET_CREATED=0
SLS_TIMEOUT_SECS="${AWSBOX_SLS_TIMEOUT_SECS:-300}"
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml")
DNS_LOG_HOST="$OUT/dnsmasq-queries.log"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
# Host-side aws CLI / asserts still talk to LocalEmu directly.
export AWS_ENDPOINT_URL="$EP"
export AWSBOX_SLS4_DEPLOY_BUCKET="$DEPLOY_BUCKET"
export AWSBOX_SLS4_SUFFIX="$SUFFIX"
export AWSBOX_SLS4_TOPIC_SERVICE="$TOPIC_SERVICE"
export AWSBOX_SLS4_CONSUMER_SERVICE="$CONSUMER_SERVICE"
export AWSBOX_SLS4_TOPIC_EXPORT="$TOPIC_EXPORT"
export CI=1
export SLS_TELEMETRY_DISABLED=1
export SLS_INTERACTIVE_SETUP_ENABLE=0

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

require_sls_auth() {
	if [[ -n "${SERVERLESS_LICENSE_KEY:-}" || -n "${SERVERLESS_ACCESS_KEY:-}" ]]; then
		return 0
	fi
	echo "error: Serverless Framework v4 needs auth for every command (incl. package)." >&2
	echo "  Free / under-\$2M: export SERVERLESS_ACCESS_KEY=…" >&2
	echo "  Paid / local maintainer: SERVERLESS_LICENSE_KEY or SERVERLESS_LOCAL_ONLY_LICENCE_KEY" >&2
	echo "  See docs/serverless-awsbox.md" >&2
	exit 1
}

redirect_id() {
	"${COMPOSE[@]}" --profile aws-redirect ps -q aws-redirect 2>/dev/null | head -1
}

redirect_ip() {
	local id
	id="$(redirect_id)"
	[[ -n "$id" ]] || return 1
	docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$id" | awk 'NF{print; exit}'
}

fetch_dns_log() {
	local id
	id="$(redirect_id)"
	[[ -n "$id" ]] || return 1
	docker exec "$id" cat /var/log/aws-redirect-dnsmasq.log >"$DNS_LOG_HOST" 2>/dev/null || true
}

# Assert AWS A answers in the dnsmasq log are only the redirect IP (fail-closed).
# Limitation: this is DNS answers only — we do not packet-capture egress. Non-AWS
# names (Serverless licence host, npm, etc.) resolve upstream by design; the log
# cannot prove "only the licence host left the machine" without brittle capture.
assert_dns_fail_closed() {
	local ip bad
	ip="$(redirect_ip)"
	[[ -n "$ip" ]] || {
		echo "error: aws-redirect IP unknown for DNS assert" >&2
		return 1
	}
	fetch_dns_log
	[[ -s "$DNS_LOG_HOST" ]] || {
		echo "error: empty dnsmasq query log" >&2
		return 1
	}
	# dnsmasq --log-queries: "config <name> is <ip>" for address=/…/ answers.
	bad="$(
		grep -E 'config .*(amazonaws\.com|amazonaws\.com\.cn|api\.aws|aws\.amazon\.com) is [0-9.]+' "$DNS_LOG_HOST" \
			| grep -Ev " is (${ip}|0\\.0\\.0\\.0)$" || true
	)"
	if [[ -n "$bad" ]]; then
		echo "error: dnsmasq answered an AWS hostname with a non-proxy IP:" >&2
		echo "$bad" >&2
		return 1
	fi
	if ! grep -Eq "config .*(sts|cloudformation|ssm|s3|sns|sqs|lambda).*amazonaws\\.com is ${ip}" "$DNS_LOG_HOST"; then
		if ! grep -Eq "config .*amazonaws\\.com is ${ip}" "$DNS_LOG_HOST"; then
			echo "error: dnsmasq log has no AWS→proxy answers (ip=${ip})" >&2
			tail -n 80 "$DNS_LOG_HOST" >&2 || true
			return 1
		fi
	fi
	echo "ok   DNS log: AWS hostnames → ${ip} only (egress allowlist not asserted; see smoke header)"
}

# Run serverless via ./bin/stackwrangler sls (container + aws-redirect DNS/TLS).
sls_run_timed() {
	local dir="$1"
	local marker="$2"
	local log="$3"
	shift 3
	set +e
	(
		timeout --signal=KILL "${SLS_TIMEOUT_SECS}" \
			env -u AWS_ENDPOINT_URL -u AWS_ENDPOINT_URL_S3 \
			"$ROOT/bin/stackwrangler" sls --cwd "$dir" -- "$@" --stage "$STAGE"
	) >"$log" 2>&1
	local rc=$?
	set -e
	if grep -qiE "$marker" "$log"; then
		sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' | grep -v '^[[:space:]]*$' || cat "$log"
		return 0
	fi
	sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' >&2 || cat "$log" >&2 || true
	echo "error: serverless did not report '${marker}' (exit ${rc}, timeout ${SLS_TIMEOUT_SECS}s)" >&2
	return 1
}

stop_tls_proxy() {
	local id
	id="$(redirect_id)"
	[[ -n "$id" ]] || return 1
	# Slim image has no pkill — kill via pid file, then any leftover tls_proxy.py.
	docker exec -i "$id" python3 - <<'PY' || true
import os, signal, pathlib
pid_path = pathlib.Path("/var/run/aws-redirect-tls.pid")
if pid_path.exists():
    try:
        os.kill(int(pid_path.read_text().strip()), signal.SIGTERM)
    except (ProcessLookupError, ValueError):
        pass
    pid_path.unlink(missing_ok=True)
for proc in pathlib.Path("/proc").iterdir():
    if not proc.name.isdigit():
        continue
    try:
        cmd = (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode()
    except OSError:
        continue
    if "tls_proxy.py" in cmd:
        try:
            os.kill(int(proc.name), signal.SIGTERM)
        except ProcessLookupError:
            pass
PY
	sleep 1
}

start_tls_proxy_again() {
	"${COMPOSE[@]}" --profile aws-redirect up -d --force-recreate aws-redirect >/dev/null
	local i id
	for i in $(seq 1 60); do
		id="$(redirect_id)"
		if [[ -n "$id" ]] && docker exec "$id" /opt/aws-redirect/healthcheck.sh >/dev/null 2>&1; then
			return 0
		fi
		sleep 1
	done
	echo "error: aws-redirect did not recover after TLS restart (DNS+TLS healthcheck)" >&2
	return 1
}

negative_tls_down() {
	echo "==> negative: DNS up, TLS proxy stopped → connection error (not real AWS)"
	local log="$OUT/negative-tls-down.log"
	local id ip network
	id="$(redirect_id)"
	ip="$(redirect_ip)"
	network="$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' "$id" | awk 'NF{print; exit}')"
	stop_tls_proxy
	set +e
	(
		timeout --signal=KILL 30 docker run --rm \
			--network "$network" \
			--dns "$ip" \
			node:20-bookworm \
			node -e 'require("https").get("https://sts.us-east-1.amazonaws.com/",(r)=>{console.log("status",r.statusCode);process.exit(0)}).on("error",(e)=>{console.error(String(e));process.exit(1)})'
	) >"$log" 2>&1
	local rc=$?
	set -e
	start_tls_proxy_again
	if grep -qiE 'security token included in the request is invalid|InvalidClientTokenId|UnrecognizedClientException|SignatureDoesNotMatch' "$log"; then
		echo "error: negative check hit real AWS auth error instead of connection failure" >&2
		cat "$log" >&2
		return 1
	fi
	if [[ "$rc" -eq 0 ]]; then
		echo "error: negative check expected connection failure, got HTTP success" >&2
		cat "$log" >&2
		return 1
	fi
	if ! grep -qiE 'ECONNREFUSED|ECONNRESET|ETIMEDOUT|ENETUNREACH|EHOSTUNREACH|socket hang up|connect ECONNREFUSED|Client network socket disconnected|connect ETIMEDOUT|AggregateError' "$log"; then
		echo "error: negative check missing connection-error marker" >&2
		cat "$log" >&2
		return 1
	fi
	echo "ok   TLS down → connection error (rc=${rc})"
}

cleanup() {
	if [[ "$KEEP" == "1" ]]; then
		return 0
	fi
	if [[ "$REMOVED" != "1" ]]; then
		if [[ "$CONSUMER_DEPLOYED" == "1" ]]; then
			(
				timeout --signal=KILL 90 \
					env -u AWS_ENDPOINT_URL -u AWS_ENDPOINT_URL_S3 \
					"$ROOT/bin/stackwrangler" sls --cwd "$EX/consumer" -- remove --stage "$STAGE" --verbose
			) >"$OUT/remove-consumer-cleanup.log" 2>&1 || true
		fi
		if [[ "$TOPIC_DEPLOYED" == "1" ]]; then
			(
				timeout --signal=KILL 90 \
					env -u AWS_ENDPOINT_URL -u AWS_ENDPOINT_URL_S3 \
					"$ROOT/bin/stackwrangler" sls --cwd "$EX/topic" -- remove --stage "$STAGE" --verbose
			) >"$OUT/remove-topic-cleanup.log" 2>&1 || true
		fi
	fi
	if [[ "$BUCKET_CREATED" == "1" ]]; then
		aws s3 rb "s3://${DEPLOY_BUCKET}" --force >/dev/null 2>&1 || true
		aws ssm delete-parameter --name "/demo/sls4/${SUFFIX}/app-name" >/dev/null 2>&1 || true
		aws ssm delete-parameter --name "/demo/sls4/${SUFFIX}/topic-arn" >/dev/null 2>&1 || true
	fi
	if [[ "$KEEP" != "1" ]]; then
		"${COMPOSE[@]}" --profile aws-redirect rm -sf aws-redirect >/dev/null 2>&1 || true
	fi
	[[ -d "$OUT" ]] && rm -rf "$OUT"
}
trap cleanup EXIT

mkdir -p "$OUT"
require_sls_auth

if ! aws sts get-caller-identity >/dev/null 2>&1; then
	echo "error: LocalEmu not reachable at ${EP} (./bin/stackwrangler up)" >&2
	exit 1
fi

if [[ ! -d "$EX/node_modules/serverless" ]]; then
	(cd "$EX" && npm install --no-fund --no-audit)
fi

echo "==> ensure aws-redirect (DNS + TLS)"
"$ROOT/bin/stackwrangler" sls --cwd "$EX/topic" -- --version >/dev/null
REDIRECT_IP="$(redirect_ip)"
echo "ok   aws-redirect at ${REDIRECT_IP}"

# Clear query log so asserts cover this run.
RID="$(redirect_id)"
docker exec "$RID" sh -c ': > /var/log/aws-redirect-dnsmasq.log' || true

negative_tls_down

aws s3 mb "s3://${DEPLOY_BUCKET}" >/dev/null
BUCKET_CREATED=1
aws ssm put-parameter \
	--name "/demo/sls4/${SUFFIX}/app-name" \
	--type String \
	--value "awsbox-sls4-smoke" \
	--overwrite >/dev/null

echo "==> serverless deploy topic (via aws-redirect, no AWS_ENDPOINT_URL)"
sls_run_timed "$EX/topic" 'Service deployed|Stack create finished|CREATE_COMPLETE' \
	"$OUT/deploy-topic.log" deploy --verbose
TOPIC_DEPLOYED=1

TOPIC_ARN="$(aws cloudformation describe-stacks --stack-name "$TOPIC_STACK" \
	--query "Stacks[0].Outputs[?OutputKey=='TopicArn'].OutputValue | [0]" \
	--output text 2>/dev/null || true)"
if [[ -z "$TOPIC_ARN" || "$TOPIC_ARN" == "None" ]]; then
	TOPIC_ARN="$(aws ssm get-parameter --name "/demo/sls4/${SUFFIX}/topic-arn" \
		--query 'Parameter.Value' --output text)"
fi
[[ -n "$TOPIC_ARN" && "$TOPIC_ARN" != "None" ]] || {
	echo "error: could not resolve TopicArn after topic deploy" >&2
	aws cloudformation describe-stacks --stack-name "$TOPIC_STACK" --output table >&2 || true
	exit 1
}
echo "ok   TopicArn=${TOPIC_ARN}"

echo "==> serverless deploy consumer (ssm + Fn::ImportValue via redirect)"
sls_run_timed "$EX/consumer" 'Service deployed|Stack create finished|CREATE_COMPLETE' \
	"$OUT/deploy-consumer.log" deploy --verbose
CONSUMER_DEPLOYED=1

RESULTS_BUCKET="${CONSUMER_SERVICE}-${STAGE}-results-${SUFFIX}"
aws s3api head-bucket --bucket "$RESULTS_BUCKET" >/dev/null 2>&1 || {
	echo "error: results bucket ${RESULTS_BUCKET} missing after consumer deploy" >&2
	aws cloudformation describe-stack-resources --stack-name "$CONSUMER_STACK" --output table >&2 || true
	exit 1
}

MSG="keep-${TS}"
echo "==> sns publish (filter keep)"
aws sns publish \
	--topic-arn "$TOPIC_ARN" \
	--message "$MSG" \
	--message-attributes "kind={DataType=String,StringValue=keep}" >/dev/null

aws sns publish \
	--topic-arn "$TOPIC_ARN" \
	--message "drop-${TS}" \
	--message-attributes "kind={DataType=String,StringValue=drop}" >/dev/null || true

echo "==> wait for Lambda → S3 marker"
found=""
for _ in $(seq 1 40); do
	if aws s3 ls "s3://${RESULTS_BUCKET}/got/" 2>/dev/null | grep -q .; then
		found=1
		break
	fi
	sleep 2
done
[[ -n "$found" ]] || {
	echo "error: no objects under s3://${RESULTS_BUCKET}/got/ after SNS publish" >&2
	aws s3 ls "s3://${RESULTS_BUCKET}/" --recursive >&2 || true
	aws lambda list-event-source-mappings --output table >&2 || true
	exit 1
}
aws s3 cp "s3://${RESULTS_BUCKET}/got/" "$OUT/got/" --recursive >/dev/null
grep -q "$MSG" "$OUT/got/"* || {
	echo "error: S3 marker missing body ${MSG}" >&2
	cat "$OUT/got/"* >&2
	exit 1
}
grep -q 'awsbox-sls4-smoke' "$OUT/got/"* || {
	echo "error: S3 marker missing APP_NAME from \${ssm:…}" >&2
	cat "$OUT/got/"* >&2
	exit 1
}
echo "ok   Lambda wrote S3 marker for ${MSG}"

echo "==> serverless deploy consumer (2 / redeploy)"
export AWSBOX_SLS4_REDEPLOY_MARK="redeploy-${TS}"
sls_run_timed "$EX/consumer" 'Updating CloudFormation stack|UPDATE_IN_PROGRESS|UPDATE_COMPLETE|Service deployed' \
	"$OUT/deploy-consumer2.log" deploy --verbose --force
if grep -qiE 'No changes to deploy' "$OUT/deploy-consumer2.log"; then
	echo "error: consumer redeploy was a no-op (No changes to deploy)" >&2
	exit 1
fi

MSG2="keep-redeploy-${TS}"
aws s3 rm "s3://${RESULTS_BUCKET}/got/" --recursive >/dev/null 2>&1 || true
aws sns publish \
	--topic-arn "$TOPIC_ARN" \
	--message "$MSG2" \
	--message-attributes "kind={DataType=String,StringValue=keep}" >/dev/null
found=""
for _ in $(seq 1 40); do
	if aws s3 ls "s3://${RESULTS_BUCKET}/got/" 2>/dev/null | grep -q .; then
		found=1
		break
	fi
	sleep 2
done
[[ -n "$found" ]] || {
	echo "error: no S3 objects after redeploy publish" >&2
	exit 1
}
aws s3 cp "s3://${RESULTS_BUCKET}/got/" "$OUT/got2/" --recursive >/dev/null
grep -q "redeploy-${TS}" "$OUT/got2/"* || {
	echo "error: post-redeploy body missing REDEPLOY_MARK=redeploy-${TS}" >&2
	cat "$OUT/got2/"* >&2
	exit 1
}

echo "==> serverless remove (consumer then topic)"
sls_run_timed "$EX/consumer" 'Service removed|Removing service|Stack removal finished|Successfully removed|removing' \
	"$OUT/remove-consumer.log" remove --verbose
sls_run_timed "$EX/topic" 'Service removed|Removing service|Stack removal finished|Successfully removed|removing' \
	"$OUT/remove-topic.log" remove --verbose
REMOVED=1

for stack in "$CONSUMER_STACK" "$TOPIC_STACK"; do
	if aws cloudformation describe-stacks --stack-name "$stack" >/dev/null 2>&1; then
		st="$(aws cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].StackStatus' --output text)"
		[[ "$st" == "DELETE_COMPLETE" ]] || {
			echo "error: stack ${stack} still ${st} after remove" >&2
			exit 1
		}
	fi
done

assert_dns_fail_closed

echo "OK: serverless v4 topic+consumer via aws-redirect (${TOPIC_STACK} → ${CONSUMER_STACK})"
