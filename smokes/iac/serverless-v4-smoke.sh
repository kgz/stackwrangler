#!/usr/bin/env bash
# Deploy examples/serverless-v4-sns-sqs (topic + consumer) via aws-redirect
# (DNS + TLS → LocalEmu). No AWS_ENDPOINT_URL on the Serverless path (#464).
#
# Happy: deploy topic+consumer → SNS keep → SQS→Lambda → redeploy → remove.
# Sad (#460): missing auth (require_sls_auth); host aws without endpoint refuses
# real AWS; TLS-down connection error; missing ImportValue deploy fails;
# filter-drop message never reaches S3.
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
KEY="${STACKWRANGLER_ACCESS_KEY:-${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}}"
REGION="${STACKWRANGLER_REGION:-${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}}"
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

# Assert AWS DNS is fail-closed for A and AAAA (no public AWS addrs).
# Limitation: DNS answers only — we do not packet-capture egress. Non-AWS
# names (Serverless licence host, npm, etc.) resolve upstream by design.
assert_dns_fail_closed() {
	local ip id bad aaaa dual
	ip="$(redirect_ip)"
	id="$(redirect_id)"
	[[ -n "$ip" && -n "$id" ]] || {
		echo "error: aws-redirect IP/id unknown for DNS assert" >&2
		return 1
	}

	# Live probe: dualstack AAAA must not be a public AWS IPv6 (local= → empty/NXDOMAIN).
	dual="$(docker exec "$id" dig +short +time=2 +tries=1 @"$ip" AAAA s3.dualstack.us-east-1.amazonaws.com 2>/dev/null || true)"
	if printf '%s\n' "$dual" | grep -Eq '^[0-9a-fA-F:]+$' && printf '%s\n' "$dual" | grep -Eqv '^(::|::1)$'; then
		echo "error: dualstack AAAA returned a public-looking IPv6 (fail-open):" >&2
		echo "$dual" >&2
		return 1
	fi
	# A still hits the proxy.
	if ! docker exec "$id" dig +short +time=2 +tries=1 @"$ip" A s3.dualstack.us-east-1.amazonaws.com 2>/dev/null | grep -qx "$ip"; then
		echo "error: dualstack A did not resolve to proxy ${ip}" >&2
		return 1
	fi

	fetch_dns_log
	[[ -s "$DNS_LOG_HOST" ]] || {
		echo "error: empty dnsmasq query log" >&2
		return 1
	}
	# IPv4 config answers must be proxy (or 0.0.0.0).
	bad="$(
		grep -E '(config|reply) .*(amazonaws\.com|amazonaws\.com\.cn|api\.aws|aws\.amazon\.com) is [0-9.]+' "$DNS_LOG_HOST" \
			| grep -Ev " is (${ip}|0\\.0\\.0\\.0)$" || true
	)"
	if [[ -n "$bad" ]]; then
		echo "error: dnsmasq answered an AWS hostname with a non-proxy IPv4:" >&2
		echo "$bad" >&2
		return 1
	fi
	# AAAA / IPv6 answers in the log must not be public (no reply/config … is <v6>).
	aaaa="$(
		grep -Ei '(config|reply) .*(amazonaws\.com|amazonaws\.com\.cn|api\.aws|aws\.amazon\.com) is [0-9a-f:]+' "$DNS_LOG_HOST" \
			| grep -E ' is [0-9a-fA-F]*:[0-9a-fA-F:]+' \
			| grep -Ev ' is (::|::1)$' || true
	)"
	if [[ -n "$aaaa" ]]; then
		echo "error: dnsmasq answered an AWS hostname with a public-looking AAAA:" >&2
		echo "$aaaa" >&2
		return 1
	fi
	if ! grep -Eq "config .*(sts|cloudformation|ssm|s3|sns|sqs|lambda).*amazonaws\\.com is ${ip}" "$DNS_LOG_HOST"; then
		if ! grep -Eq "config .*amazonaws\\.com is ${ip}" "$DNS_LOG_HOST"; then
			echo "error: dnsmasq log has no AWS→proxy A answers (ip=${ip})" >&2
			tail -n 80 "$DNS_LOG_HOST" >&2 || true
			return 1
		fi
	fi
	echo "ok   DNS fail-closed: A→${ip}, dualstack AAAA not public (egress allowlist not asserted)"
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

# Host aws without --endpoint-url / AWS_ENDPOINT_URL must not succeed against a
# real account (fake LocalEmu keys → InvalidClientTokenId or similar).
negative_host_aws_without_endpoint() {
	echo "==> negative: host aws without AWS_ENDPOINT_URL refuses real AWS"
	local log="$OUT/negative-no-endpoint.log" out rc
	set +e
	out="$(
		env -u AWS_ENDPOINT_URL -u AWS_ENDPOINT_URL_S3 \
			AWS_ACCESS_KEY_ID="$KEY" \
			AWS_SECRET_ACCESS_KEY="$SECRET" \
			AWS_DEFAULT_REGION="$REGION" \
			AWS_CONFIG_FILE=/dev/null \
			AWS_SHARED_CREDENTIALS_FILE=/dev/null \
			AWS_EC2_METADATA_DISABLED=true \
			command aws --region "$REGION" sts get-caller-identity 2>&1
	)"
	rc=$?
	set -e
	printf '%s\n' "$out" >"$log"
	if [[ "$rc" -eq 0 ]]; then
		echo "error: host aws without endpoint succeeded (would hit real AWS):" >&2
		cat "$log" >&2
		return 1
	fi
	if echo "$out" | grep -qiE 'Account[" ]*[:=].*[1-9][0-9]{11}'; then
		echo "error: host aws without endpoint returned a real-looking Account id" >&2
		cat "$log" >&2
		return 1
	fi
	echo "ok   host aws without endpoint refused (rc=${rc})"
}

# Consumer deploy with a non-existent CFN export must fail (not CREATE_COMPLETE).
negative_import_value() {
	echo "==> negative: consumer deploy with missing Fn::ImportValue export fails"
	local bad_svc="awsbox-sls4-badimp-${TS}"
	local bad_stack="${bad_svc}-${STAGE}"
	# Name must not contain words our failure grep uses (no "missing"/"fail").
	local bad_export="awsbox-sls4-noexport-${TS}-TopicArn"
	local log="$OUT/negative-importvalue.log"
	local prev_svc prev_export rc
	prev_svc="${AWSBOX_SLS4_CONSUMER_SERVICE}"
	prev_export="${AWSBOX_SLS4_TOPIC_EXPORT}"
	export AWSBOX_SLS4_CONSUMER_SERVICE="$bad_svc"
	export AWSBOX_SLS4_TOPIC_EXPORT="$bad_export"
	set +e
	(
		timeout --signal=KILL "${SLS_TIMEOUT_SECS}" \
			env -u AWS_ENDPOINT_URL -u AWS_ENDPOINT_URL_S3 \
			"$ROOT/bin/stackwrangler" sls --cwd "$EX/consumer" -- deploy --stage "$STAGE" --verbose
	) >"$log" 2>&1
	rc=$?
	set -e
	export AWSBOX_SLS4_CONSUMER_SERVICE="$prev_svc"
	export AWSBOX_SLS4_TOPIC_EXPORT="$prev_export"
	# Best-effort cleanup of a partial bad stack (KEEP=0 path too).
	(
		timeout --signal=KILL 90 \
			env -u AWS_ENDPOINT_URL -u AWS_ENDPOINT_URL_S3 \
			AWSBOX_SLS4_CONSUMER_SERVICE="$bad_svc" \
			AWSBOX_SLS4_TOPIC_EXPORT="$bad_export" \
			"$ROOT/bin/stackwrangler" sls --cwd "$EX/consumer" -- remove --stage "$STAGE" --verbose
	) >"$OUT/negative-importvalue-remove.log" 2>&1 || true
	aws cloudformation delete-stack --stack-name "$bad_stack" >/dev/null 2>&1 || true

	# Template dumps contain "Fn::ImportValue" even on success — never treat that
	# alone as the sad-path failure signal.
	if grep -qiE 'Service deployed|Stack create finished' "$log" \
		|| { grep -qiE 'CREATE_COMPLETE' "$log" && ! grep -qiE 'CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|ROLLBACK_IN_PROGRESS' "$log"; }; then
		echo "error: missing-ImportValue deploy looked successful (must not pass)" >&2
		sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' | tail -80 >&2 || true
		return 1
	fi
	# Explicit missing-export / stack-failure markers only — not bare non-zero,
	# and not the substring "ImportValue" from a dumped template.
	if grep -qiE 'No export named|ExportNotFound|cannot find export|Could not find export|Unresolved resource dependencies|CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED' "$log"; then
		echo "ok   missing ImportValue deploy failed as expected (rc=${rc})"
		return 0
	fi
	echo "error: missing-ImportValue deploy did not show a missing-export failure marker" >&2
	sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$log" | tr -d '\r' | tail -80 >&2 || true
	return 1
}

# Write optional ≥2 MiB pad so consumer zip triggers SDK v2 Expect: 100-continue (#467).
# Use high-entropy bytes so deflate cannot shrink the artifact under ~1 MiB.
ensure_large_consumer_pad() {
	local pad="$EX/consumer/src/pad-blob.js"
	python3 - "$pad" <<'PY'
import base64
import secrets
import sys
from pathlib import Path

path = Path(sys.argv[1])
raw = secrets.token_bytes(2_200_000)
b64 = base64.b64encode(raw).decode("ascii")
path.write_text(
    "// high-entropy pad for #467 — do not commit\n"
    "module.exports = Buffer.from(" + repr(b64) + ", 'base64')\n",
    encoding="utf-8",
)
print(path.stat().st_size)
PY
}

assert_consumer_zip_ge_2mb() {
	local z max=0 size
	shopt -s nullglob
	for z in "$EX/consumer/.serverless"/*.zip; do
		size="$(wc -c <"$z" | tr -d ' ')"
		if [[ "$size" -gt "$max" ]]; then
			max="$size"
		fi
	done
	shopt -u nullglob
	if [[ "$max" -lt 2097152 ]]; then
		echo "error: consumer Lambda zip ${max} bytes; need ≥2097152 for Expect: 100-continue smoke (#467)" >&2
		ls -la "$EX/consumer/.serverless"/*.zip 2>/dev/null >&2 || true
		return 1
	fi
	echo "ok   consumer zip ${max} bytes (≥2 MiB; Expect: 100-continue path)"
}

# stackwrangler sls must not leave root-owned files under the project (#469).
assert_host_owned() {
	local dir="$1"
	local label="${2:-$dir}"
	local uid gid bad
	uid="$(id -u)"
	gid="$(id -g)"
	[[ -d "$dir" ]] || {
		echo "error: expected ${label} after sls write" >&2
		return 1
	}
	bad="$(find "$dir" \( ! -uid "$uid" -o ! -gid "$gid" \) -print 2>/dev/null | head -20 || true)"
	if [[ -n "$bad" ]]; then
		echo "error: ${label} has files not owned by ${uid}:${gid} (invoking user):" >&2
		echo "$bad" >&2
		ls -la "$dir" >&2 || true
		return 1
	fi
	# Host-side cleanup must work without sudo / another container.
	rm -rf "${dir}.ownership-check"
	cp -a "$dir" "${dir}.ownership-check"
	rm -rf "${dir}.ownership-check" || {
		echo "error: could not delete copy of ${label} as invoking user" >&2
		return 1
	}
	echo "ok   ${label} owned by ${uid}:${gid} (host-deletable)"
}

cleanup() {
	rm -f "$EX/consumer/src/pad-blob.js"
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
negative_host_aws_without_endpoint

aws s3 mb "s3://${DEPLOY_BUCKET}" >/dev/null
BUCKET_CREATED=1
aws ssm put-parameter \
	--name "/demo/sls4/${SUFFIX}/app-name" \
	--type String \
	--value "awsbox-sls4-smoke" \
	--overwrite >/dev/null

echo "==> serverless package topic (ownership before deploy)"
sls_run_timed "$EX/topic" 'Service packaged|Packaging service|✔ Service packaged' \
	"$OUT/package-topic.log" package --verbose
assert_host_owned "$EX/topic/.serverless" "topic/.serverless (after package)"

echo "==> serverless deploy topic (via aws-redirect, no AWS_ENDPOINT_URL)"
sls_run_timed "$EX/topic" 'Service deployed|Stack create finished|CREATE_COMPLETE' \
	"$OUT/deploy-topic.log" deploy --verbose
TOPIC_DEPLOYED=1
assert_host_owned "$EX/topic/.serverless" "topic/.serverless (after deploy)"

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

# Before the happy consumer (and its ≥2 MiB pad): missing export must fail.
negative_import_value

echo "==> pad consumer Lambda (≥2 MiB zip → Expect: 100-continue on S3 upload)"
PAD_BYTES="$(ensure_large_consumer_pad)"
echo "ok   wrote consumer/src/pad-blob.js (${PAD_BYTES} bytes source)"

echo "==> serverless deploy consumer (ssm + Fn::ImportValue via redirect)"
sls_run_timed "$EX/consumer" 'Service deployed|Stack create finished|CREATE_COMPLETE' \
	"$OUT/deploy-consumer.log" deploy --verbose
CONSUMER_DEPLOYED=1
assert_consumer_zip_ge_2mb
assert_host_owned "$EX/consumer/.serverless" "consumer/.serverless (after deploy)"

RESULTS_BUCKET="${CONSUMER_SERVICE}-${STAGE}-results-${SUFFIX}"
aws s3api head-bucket --bucket "$RESULTS_BUCKET" >/dev/null 2>&1 || {
	echo "error: results bucket ${RESULTS_BUCKET} missing after consumer deploy" >&2
	aws cloudformation describe-stack-resources --stack-name "$CONSUMER_STACK" --output table >&2 || true
	exit 1
}

MSG="keep-${TS}"
DROP_MSG="drop-${TS}"
echo "==> sns publish (filter keep + filter drop)"
aws sns publish \
	--topic-arn "$TOPIC_ARN" \
	--message "$MSG" \
	--message-attributes "kind={DataType=String,StringValue=keep}" >/dev/null

aws sns publish \
	--topic-arn "$TOPIC_ARN" \
	--message "$DROP_MSG" \
	--message-attributes "kind={DataType=String,StringValue=drop}" >/dev/null

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

# FilterPolicy kind=keep: drop body must never appear (settle briefly for late delivery).
sleep 5
aws s3 cp "s3://${RESULTS_BUCKET}/got/" "$OUT/got-after-drop/" --recursive >/dev/null 2>&1 || true
if grep -rq -- "$DROP_MSG" "$OUT/got" "$OUT/got-after-drop" 2>/dev/null; then
	echo "error: filter-drop message ${DROP_MSG} appeared under results (FilterPolicy leak)" >&2
	grep -r -- "$DROP_MSG" "$OUT/got" "$OUT/got-after-drop" >&2 || true
	exit 1
fi
got_n="$(find "$OUT/got-after-drop" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${got_n:-0}" -gt 1 ]]; then
	echo "error: expected one S3 marker after keep+drop publish, found ${got_n}" >&2
	ls -la "$OUT/got-after-drop" >&2 || true
	exit 1
fi
echo "ok   filter drop: ${DROP_MSG} absent from S3 (got_n=${got_n})"

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
