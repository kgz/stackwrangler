#!/usr/bin/env bash
# #770: PERSISTENCE=1 LocalEmu restart keeps ELBv2 API state + rebuilds listeners.
#
# Creates an internal ALB with an HTTPS listener, a path rule, and a registered
# IP target; restarts LocalEmu; assert describe-* still returns everything and a
# request through the listener reaches the target without re-applying.
#
# Requires an already-up stackwrangler compose project for this worktree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
KEEP="${STACKWRANGLER_ELBV2_PERSIST_KEEP:-${AWSBOX_ELBV2_PERSIST_KEEP:-0}}"
OVERRIDE="${TMPDIR:-/tmp}/awsbox-elbv2-persist-override-${TS}.yml"
STATE_VOL="awsl-elbv2-persist-${TS}"
PROJECT="$(basename "$ROOT")"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml" -f "$OVERRIDE")
BASE_COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")
TARGET_NAME="elbv2-persist-tgt-${TS}"
HTTPS_PORT=$((18443 + (TS % 100)))
MARKER="persist-${TS}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

wait_localemu() {
	local code=""
	for _ in $(seq 1 90); do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${EP}/" || true)"
		[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && return 0
		sleep 2
	done
	fail "LocalEmu not ready (http ${code:-none})"
}

restore_default_localstack() {
	rm -f "$OVERRIDE"
	"${BASE_COMPOSE[@]}" up -d --force-recreate --no-deps localstack >/dev/null 2>&1 || true
	wait_localemu >/dev/null 2>&1 || true
	docker volume rm -f "$STATE_VOL" >/dev/null 2>&1 || true
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	docker rm -f "$TARGET_NAME" >/dev/null 2>&1 || true
	[[ -n "${LIS:-}" ]] && aws elbv2 delete-listener --listener-arn "$LIS" >/dev/null 2>&1 || true
	[[ -n "${LB:-}" ]] && aws elbv2 delete-load-balancer --load-balancer-arn "$LB" >/dev/null 2>&1 || true
	[[ -n "${TG:-}" ]] && aws elbv2 delete-target-group --target-group-arn "$TG" >/dev/null 2>&1 || true
	[[ -n "${SG:-}" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "${SUB_A:-}" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1 || true
	[[ -n "${SUB_B:-}" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1 || true
	[[ -n "${VPC:-}" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	restore_default_localstack
}
trap cleanup EXIT

LS_ID="$("${BASE_COMPOSE[@]}" ps -q localstack 2>/dev/null || true)"
[[ -n "$LS_ID" ]] || fail "localstack not up — run ./bin/stackwrangler up first"

cat >"$OVERRIDE" <<YAML
services:
  localstack:
    environment:
      PERSISTENCE: "1"
    volumes:
      - ${STATE_VOL}:/var/lib/localemu
volumes:
  ${STATE_VOL}:
    name: ${STATE_VOL}
YAML

start_localstack_persist() {
	echo "start localstack (PERSISTENCE=1)"
	"${COMPOSE[@]}" up -d --no-deps localstack >/dev/null
	wait_localemu
	sleep 3
}

restart_localstack_persist() {
	echo "restart localstack (PERSISTENCE=1, graceful)"
	"${COMPOSE[@]}" stop localstack >/dev/null
	"${COMPOSE[@]}" up -d --no-deps localstack >/dev/null
	wait_localemu
	# Router rebuild + VPC join can lag briefly after hooks fire.
	sleep 5
}

echo "== enable PERSISTENCE=1 + unique state volume ${STATE_VOL} =="
"${BASE_COMPOSE[@]}" stop localstack >/dev/null 2>&1 || true
start_localstack_persist

echo "== vpc + target on VPC network =="
VPC="$(aws ec2 create-vpc --cidr-block 10.217.0.0/16 --query 'Vpc.VpcId' --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.217.1.0/24 --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.217.2.0/24 --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)"
SG="$(aws ec2 create-security-group --group-name "elbv2-persist-${TS}" --description "elbv2 persist" --vpc-id "$VPC" --query 'GroupId' --output text)"
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port "$HTTPS_PORT" --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$SG" --protocol tcp --port 8080 --cidr 0.0.0.0/0 >/dev/null
aws ec2 authorize-security-group-egress --group-id "$SG" --ip-permissions '[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true

# CreateVpc ensures localemu-vpc-<id>; wait for the bridge before attaching a target.
NET="localemu-vpc-${VPC}"
for _ in $(seq 1 40); do
	if docker network inspect "$NET" >/dev/null 2>&1; then
		break
	fi
	sleep 1
done
docker network inspect "$NET" >/dev/null 2>&1 || fail "VPC docker network ${NET} missing after CreateVpc"

docker rm -f "$TARGET_NAME" >/dev/null 2>&1 || true
docker run -d --name "$TARGET_NAME" --network "$NET" --network-alias tgt \
	python:3.12-alpine \
	python -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'${MARKER}\\n'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
socketserver.TCPServer(('0.0.0.0', 8080), H).serve_forever()
" >/dev/null
TARGET_IP="$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$TARGET_NAME")"
[[ -n "$TARGET_IP" ]] || fail "target container has no IP on ${NET}"
echo "target_ip=${TARGET_IP}"

echo "== ALB + HTTPS listener + rule + target =="
TG="$(aws elbv2 create-target-group --name "tg${TS}" --protocol HTTP --port 8080 \
	--vpc-id "$VPC" --target-type ip \
	--health-check-protocol HTTP --health-check-path / --health-check-port 8080 \
	--query 'TargetGroups[0].TargetGroupArn' --output text)"
aws elbv2 register-targets --target-group-arn "$TG" --targets "Id=${TARGET_IP},Port=8080" >/dev/null

LB="$(aws elbv2 create-load-balancer --name "alb${TS}" --type application \
	--scheme internal --subnets "$SUB_A" "$SUB_B" --security-groups "$SG" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text)"
LB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB" \
	--query 'LoadBalancers[0].DNSName' --output text)"
CERT="$(aws acm request-certificate --domain-name "elbv2-persist-${TS}.local" \
	--validation-method DNS --query 'CertificateArn' --output text)"
LIS="$(aws elbv2 create-listener --load-balancer-arn "$LB" --protocol HTTPS \
	--port "$HTTPS_PORT" --certificates "CertificateArn=${CERT}" \
	--default-actions "Type=forward,TargetGroupArn=${TG}" \
	--query 'Listeners[0].ListenerArn' --output text)"
# Non-default rule must round-trip after restore (conditions + forward).
RULE="$(aws elbv2 create-rule --listener-arn "$LIS" --priority 10 \
	--conditions '[{"Field":"path-pattern","PathPatternConfig":{"Values":["/v1/*"]}}]' \
	--actions "Type=forward,TargetGroupArn=${TG}" \
	--query 'Rules[0].RuleArn' --output text)"

wait_healthy() {
	local n=""
	for _ in $(seq 1 40); do
		n="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
			--query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text 2>/dev/null || true)"
		[[ "$n" == "1" ]] && return 0
		sleep 2
	done
	aws elbv2 describe-target-health --target-group-arn "$TG" >&2 || true
	fail "target not healthy before restart (healthy=${n:-none})"
}
wait_healthy

lb_vpc_ip() {
	local ls_id ip=""
	ls_id="$("${COMPOSE[@]}" ps -q localstack 2>/dev/null || true)"
	[[ -n "$ls_id" ]] || return 1
	ip="$(docker inspect -f "{{(index .NetworkSettings.Networks \"${NET}\").IPAddress}}" "$ls_id" 2>/dev/null || true)"
	[[ -n "$ip" ]] || return 1
	echo "$ip"
}

hit_listener() {
	local ip out=""
	ip="$(lb_vpc_ip)" || return 1
	# Dial the LB VPC address directly — ephemeral curl containers do not get
	# LocalEmu's /etc/hosts DNS injection for the ALB name.
	out="$(docker run --rm --network "$NET" curlimages/curl:8.5.0 \
		-sk --max-time 10 -H "Host: ${LB_DNS}" \
		"https://${ip}:${HTTPS_PORT}/v1/ping" || true)"
	echo "$out"
}

BEFORE="$(hit_listener)"
echo "$BEFORE" | grep -q "$MARKER" || fail "pre-restart request missed target (got ${BEFORE})"
echo "OK: pre-restart HTTPS request reached target"

echo "== LocalEmu restart keeps ELBv2 =="
restart_localstack_persist

# Target container is outside LocalEmu — keep it; only the API/router must restore.
aws elbv2 describe-load-balancers --load-balancer-arns "$LB" \
	--query 'LoadBalancers[0].LoadBalancerArn' --output text | grep -q "$LB" \
	|| fail "LoadBalancerNotFound after restart"
aws elbv2 describe-target-groups --target-group-arns "$TG" \
	--query 'TargetGroups[0].TargetGroupArn' --output text | grep -q "$TG" \
	|| fail "target group missing after restart"
aws elbv2 describe-listeners --listener-arns "$LIS" \
	--query 'Listeners[0].ListenerArn' --output text | grep -q "$LIS" \
	|| fail "listener missing after restart"
aws elbv2 describe-rules --rule-arns "$RULE" \
	--query 'Rules[0].RuleArn' --output text | grep -q "$RULE" \
	|| fail "rule missing after restart"
TG_COUNT="$(aws elbv2 describe-target-groups --query 'length(TargetGroups)' --output text)"
[[ "$TG_COUNT" -ge 1 ]] || fail "describe-target-groups empty after restart"
REG="$(aws elbv2 describe-target-health --target-group-arn "$TG" \
	--query 'length(TargetHealthDescriptions)' --output text)"
[[ "$REG" -ge 1 ]] || fail "registered targets lost after restart"
echo "OK: describe-* kept LB/listener/rule/TG/targets"

# DNS may need a moment for hosts republish after restore.
for _ in $(seq 1 20); do
	AFTER="$(hit_listener)"
	if echo "$AFTER" | grep -q "$MARKER"; then
		echo "OK: post-restart HTTPS request reached target without re-apply"
		echo "OK: elbv2-persist-restart (#770)"
		exit 0
	fi
	sleep 2
done
fail "post-restart request missed target (last=${AFTER:-none})"
