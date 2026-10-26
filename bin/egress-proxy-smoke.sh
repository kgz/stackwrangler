#!/usr/bin/env bash
# Private-subnet ECS task reaches the "internet" only through an egress proxy.
# - VPC with no 0.0.0.0/0 route; awsvpc task with HTTP(S)_PROXY -> proxy on the
#   VPC bridge gateway (host side); proxy forwards to a local "public" target.
# - Happy: fetch via proxy, proxy log shows it.
# - Sad: same task, proxy env unset -> no direct route to the target.
# - Sad: proxy allowlist refuses another target -> task sees the proxy's 403.
# - NO_PROXY: the task still reaches the emulator endpoint without the proxy.
# - Non-root image (curlimages/curl): no default route still blocks direct egress.
# Asserts what real AWS does; every FAIL is reported, rc=1 if any.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
OK_IP="203.0.113.10"
DENY_IP="203.0.113.20"
CLUSTER="awsbox-egress-${TS}"
FAMILY="awsbox-egress-${TS}"
WORKDIR="$(mktemp -d)"
PIDS=()
ADDED_IPS=()
VPC="" SUB="" TASK=""
FAILS=0

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	for p in "${PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null || true; done
	for ip in "${ADDED_IPS[@]:-}"; do [[ -n "$ip" ]] && sudo -n ip addr del "${ip}/32" dev lo 2>/dev/null || true; done
	if [[ "$KEEP" != "1" ]]; then
		for t in $(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns[]' --output text 2>/dev/null); do
			aws ecs stop-task --cluster "$CLUSTER" --task "$t" >/dev/null 2>&1 || true
		done
		for _ in $(seq 1 20); do
			aws ecs delete-cluster --cluster "$CLUSTER" --query 'cluster.status' --output text 2>/dev/null | grep -q INACTIVE && break
			sleep 1
		done
		[[ -n "$SUB" ]] && aws ec2 delete-subnet --subnet-id "$SUB" >/dev/null 2>&1 || true
		[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	fi
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

ok() { echo "ok  $*"; }
bad() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

free_port() {
	python3 -c 'import socket,sys; s=socket.socket(); s.bind((sys.argv[1], 0)); print(s.getsockname()[1])' "$1"
}

# --- fake public targets (documentation range, bound on lo) ---
for ip in "$OK_IP" "$DENY_IP"; do
	if ! ip -4 addr show dev lo | grep -q "${ip}/"; then
		sudo -n ip addr add "${ip}/32" dev lo
		ADDED_IPS+=("$ip")
	fi
done
TPORT="$(free_port "$OK_IP")"

cat > "$WORKDIR/target.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
ip, port, body, log = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode(), sys.argv[4]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        open(log, "a").write(f"{self.client_address[0]} GET {self.path}\n")
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
HTTPServer((ip, port), H).serve_forever()
PY
python3 "$WORKDIR/target.py" "$OK_IP" "$TPORT" public-ok "$WORKDIR/ok.log" & PIDS+=($!)
python3 "$WORKDIR/target.py" "$DENY_IP" "$TPORT" denied-target-reached "$WORKDIR/deny.log" & PIDS+=($!)

# --- forward proxy: HTTP absolute-URI GET, host:port allowlist, request log ---
cat > "$WORKDIR/proxy.py" <<'PY'
import http.client, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
bind, port, allow, log = sys.argv[1], int(sys.argv[2]), set(sys.argv[3].split(",")), sys.argv[4]
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        hp = f"{u.hostname}:{u.port or 80}"
        verdict = "ALLOW" if hp in allow else "DENY"
        open(log, "a").write(f"{verdict} GET {hp}{u.path or '/'}\n")
        if verdict == "DENY":
            body, code = f"egress-proxy: {hp} not allowed\n".encode(), 403
        else:
            try:
                c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=5)
                c.request("GET", u.path or "/"); r = c.getresponse(); body, code = r.read(), r.status
            except Exception as e:
                body, code = f"egress-proxy: upstream {e}\n".encode(), 502
        self.send_response(code); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
ThreadingHTTPServer((bind, port), H).serve_forever()
PY

# --- VPC: no default route ---
OCT=$((100 + RANDOM % 100))
VPC="$(aws ec2 create-vpc --cidr-block "10.${OCT}.0.0/16" --query Vpc.VpcId --output text)"
SUB="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "10.${OCT}.1.0/24" --query Subnet.SubnetId --output text)"
DEFAULTS="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" \
	--query 'length(RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`][])' --output text)"
[[ "$DEFAULTS" == "0" ]] && ok "VPC ${VPC} route table has no default route" || bad "VPC route table has ${DEFAULTS} default route(s)"

# Proxy lives on the VPC bridge gateway (inside the VPC CIDR, on the host).
# The bridge only exists once a workload starts, so a probe task creates it first.
aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
register() {
	aws ecs register-task-definition --family "$1" --network-mode awsvpc \
		--requires-compatibilities FARGATE --cpu 256 --memory 512 --container-definitions "$2" >/dev/null
}
run() {
	aws ecs run-task --cluster "$CLUSTER" --task-definition "$1" --launch-type FARGATE \
		--network-configuration "awsvpcConfiguration={subnets=[${SUB}],securityGroups=[],assignPublicIp=DISABLED}" \
		--query 'tasks[0].taskArn' --output text
}
register "${FAMILY}-probe" '[{"name":"c","image":"alpine:3.20","essential":true,"memory":64,"command":["sleep","60"]}]'
PROBE="$(run "${FAMILY}-probe")"
GW=""
for _ in $(seq 1 30); do
	GW="$(docker network inspect "localemu-vpc-${VPC}" --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || true)"
	[[ -n "$GW" ]] && break
	sleep 1
done
aws ecs stop-task --cluster "$CLUSTER" --task "$PROBE" >/dev/null 2>&1 || true
[[ -n "$GW" ]] || { echo "FAIL: no bridge gateway for ${VPC}" >&2; exit 1; }
PPORT="$(free_port "$GW")"
python3 "$WORKDIR/proxy.py" "$GW" "$PPORT" "${OK_IP}:${TPORT}" "$WORKDIR/proxy.log" & PIDS+=($!)
sleep 1
curl -sf --noproxy '*' --max-time 3 "http://${OK_IP}:${TPORT}/" | grep -q public-ok || { echo "FAIL: target not up" >&2; exit 1; }
: > "$WORKDIR/ok.log"; : > "$WORKDIR/proxy.log"

PROXY_URL="http://${GW}:${PPORT}"
NOP="127.0.0.1,localhost,host.docker.internal"
CDEFS="[{\"name\":\"c\",\"image\":\"alpine:3.20\",\"essential\":true,\"memory\":128,\"command\":[\"sleep\",\"3600\"],\"environment\":[
{\"name\":\"HTTP_PROXY\",\"value\":\"${PROXY_URL}\"},{\"name\":\"http_proxy\",\"value\":\"${PROXY_URL}\"},
{\"name\":\"HTTPS_PROXY\",\"value\":\"${PROXY_URL}\"},{\"name\":\"https_proxy\",\"value\":\"${PROXY_URL}\"},
{\"name\":\"NO_PROXY\",\"value\":\"${NOP}\"},{\"name\":\"no_proxy\",\"value\":\"${NOP}\"}]}]"
register "$FAMILY" "$CDEFS"
TASK="$(run "$FAMILY")"
CTR=""
for _ in $(seq 1 30); do
	CTR="$(docker ps --filter "label=localemu.task-arn=${TASK}" --format '{{.Names}}' | head -1 || true)"
	[[ -n "$CTR" ]] && docker exec "$CTR" true >/dev/null 2>&1 && break
	CTR=""; sleep 2
done
[[ -n "$CTR" ]] || { echo "FAIL: task container not usable" >&2; aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" >&2; exit 1; }
echo "task=${TASK##*/} ctr=${CTR} proxy=${PROXY_URL} target=http://${OK_IP}:${TPORT}/"
dx() { docker exec "$CTR" sh -c "$1" 2>&1; }

# 0) awsvpc must not sit on the default docker bridge (#271)
ROUTES="$(dx 'ip route' || true)"
NETS="$(docker inspect "$CTR" --format '{{range $k, $_ := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)"
if echo "$NETS" | grep -qw bridge || echo "$ROUTES" | grep -qE '(^|[[:space:]])172\.17\.'; then
	bad "awsvpc still on default bridge (nets='${NETS}' routes='${ROUTES//$'\n'/; }')"
else
	ok "awsvpc not on default bridge (nets=${NETS% } routes=${ROUTES//$'\n'/; })"
fi

# 1) happy: via proxy env
OUT="$(dx "wget -qO- -T5 http://${OK_IP}:${TPORT}/" || true)"
if [[ "$OUT" == *public-ok* ]] && grep -q "ALLOW GET ${OK_IP}:${TPORT}/" "$WORKDIR/proxy.log"; then
	ok "task fetched target via proxy; proxy log shows it"
else
	bad "happy path via proxy: got '${OUT}'; proxy log: $(cat "$WORKDIR/proxy.log")"
fi

# 2) sad: proxy env removed -> direct, no default route
: > "$WORKDIR/ok.log"; : > "$WORKDIR/proxy.log"
OUT="$(dx "env -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy wget -qO- -T4 http://${OK_IP}:${TPORT}/" || true)"
if [[ "$OUT" != *public-ok* && ! -s "$WORKDIR/ok.log" ]]; then
	ok "no proxy env: direct fetch blocked (${OUT:0:60})"
else
	bad "no proxy env: task reached target directly (out='${OUT}', target saw: $(cat "$WORKDIR/ok.log")); routes: $(dx 'ip route' | tr '\n' ';')"
fi
[[ ! -s "$WORKDIR/proxy.log" ]] || bad "proxy saw traffic with proxy env unset"

# 3) sad: proxy refuses a non-allowlisted target
OUT="$(dx "wget -S -O- -T5 http://${DENY_IP}:${TPORT}/" || true)"
if [[ "$OUT" == *"403"* && "$OUT" != *denied-target-reached* && ! -s "$WORKDIR/deny.log" ]] \
	&& grep -q "DENY GET ${DENY_IP}:${TPORT}/" "$WORKDIR/proxy.log"; then
	ok "proxy refused non-allowlisted target (403), target never hit"
else
	bad "refusal: expected 403 from proxy; got '${OUT}'; target saw: $(cat "$WORKDIR/deny.log")"
fi

# 4) NO_PROXY: emulator endpoint from the task env, not via the proxy
: > "$WORKDIR/proxy.log"
EMU_URL="$(dx 'echo $AWS_ENDPOINT_URL')"
EMU_HOST="${EMU_URL#*://}"; EMU_HOST="${EMU_HOST%%/*}"; EMU_HOST="${EMU_HOST%%:*}"
# busybox wget ignores NO_PROXY, so the task shell applies it the way curl/SDKs do.
# LocalEmu serves health at /_localemu/health (/_localstack/health is IAM 403).
OUT="$(dx 'h=${AWS_ENDPOINT_URL#*//}; h=${h%%/*}; h=${h%%:*}; case ",$NO_PROXY," in *",$h,"*) unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY;; esac; wget -qO- -T4 "$AWS_ENDPOINT_URL/_localemu/health"' || true)"
if [[ "$OUT" == *'"services"'* ]] && ! grep -qF "$EMU_HOST" "$WORKDIR/proxy.log"; then
	ok "task reached emulator endpoint directly (NO_PROXY respected)"
else
	bad "emulator endpoint (\$AWS_ENDPOINT_URL=${EMU_URL}) not reachable from task: '${OUT:0:120}'; proxy log: $(cat "$WORKDIR/proxy.log")"
fi

# 5) non-root image: no default route still blocks direct egress (#270)
register "${FAMILY}-nonroot" '[{"name":"c","image":"curlimages/curl:8.5.0","essential":true,"memory":128,"command":["sleep","3600"]}]'
NR_TASK="$(run "${FAMILY}-nonroot")"
NR_CTR=""
for _ in $(seq 1 30); do
	NR_CTR="$(docker ps --filter "label=localemu.task-arn=${NR_TASK}" --format '{{.Names}}' | head -1 || true)"
	[[ -n "$NR_CTR" ]] && docker exec "$NR_CTR" true >/dev/null 2>&1 && break
	NR_CTR=""; sleep 2
done
if [[ -z "$NR_CTR" ]]; then
	bad "non-root task container not usable ($(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$NR_TASK" --query 'tasks[0].{last:lastStatus,stop:stoppedReason}' --output text 2>/dev/null || true))"
else
	: > "$WORKDIR/ok.log"
	# Image user is curl_user; route sync must still remove the default as root.
	NR_OUT="$(docker exec "$NR_CTR" curl -sS --max-time 4 "http://${OK_IP}:${TPORT}/" 2>&1 || true)"
	NR_UID="$(docker exec "$NR_CTR" id -u 2>/dev/null || true)"
	if [[ "$NR_UID" != "0" && "$NR_OUT" != *public-ok* && ! -s "$WORKDIR/ok.log" ]]; then
		ok "non-root image (uid=${NR_UID}): direct fetch blocked (${NR_OUT:0:60})"
	else
		bad "non-root: expected block for uid!=0; uid='${NR_UID}' out='${NR_OUT}' target=$(cat "$WORKDIR/ok.log"); routes: $(docker exec -u 0 "$NR_CTR" ip route 2>/dev/null | tr '\n' ';')"
	fi
fi

if [[ "$FAILS" -ne 0 ]]; then
	echo "FAIL: egress proxy smoke (${FAILS} assertion(s) failed)" >&2
	exit 1
fi
echo "OK: egress proxy smoke"
