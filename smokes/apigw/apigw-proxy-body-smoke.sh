#!/usr/bin/env bash
# REST HTTP_PROXY must forward the raw request body (AWS parity).
# curl -d defaults to application/x-www-form-urlencoded; without the #364 patch
# LocalEmu re-encodes {"a":"1"} to percent-form and backends reject it.
#
# Happy: default CT + explicit application/json both deliver exact bytes.
# Sad: re-encoded body would not match WANT (asserted by exact equality).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
TS="$(date +%s)"
KEEP="${AWSBOX_APIGW_PROXY_BODY_KEEP:-${AWSBOX_AUTHZ_KEEP:-0}}"
WORK="$ROOT/.awsbox/apigw-proxy-body-${TS}"
WANT='{"a":"1"}'
API_ID=""
PIDS=()

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	local pid
	for pid in "${PIDS[@]:-}"; do
		kill "$pid" >/dev/null 2>&1 || true
	done
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$API_ID" ]] && aws apigateway delete-rest-api --rest-api-id "$API_ID" >/dev/null 2>&1 || true
}
trap cleanup EXIT

FAIL=0
check() {
	local label="$1" want="$2" got="$3"
	if [[ "$got" == "$want" ]]; then
		echo "ok   ${label}: ${got}"
	else
		echo "FAIL ${label}: got ${got@Q}, want ${want@Q}" >&2
		FAIL=1
	fi
}

mkdir -p "$WORK"

BIND="$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')"
[[ -n "$BIND" ]] || {
	echo "FAIL: cannot determine docker bridge gateway" >&2
	exit 1
}

cat >"$WORK/echo.py" <<'PY'
from http.server import BaseHTTPRequestHandler, HTTPServer
import sys

bind, port, log_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n)
        with open(log_path, "ab") as f:
            f.write(body + b"\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer((bind, port), H).serve_forever()
PY

PORT="$(python3 -c 'import socket,sys; s=socket.socket(); s.bind((sys.argv[1],0)); print(s.getsockname()[1])' "$BIND")"
: >"$WORK/bodies.log"
python3 "$WORK/echo.py" "$BIND" "$PORT" "$WORK/bodies.log" >/dev/null 2>&1 &
PIDS+=("$!")
for _ in $(seq 1 50); do
	python3 -c 'import socket,sys; socket.create_connection((sys.argv[1],int(sys.argv[2])),1)' "$BIND" "$PORT" 2>/dev/null && break
	sleep 0.1
done

BACKEND="http://host.docker.internal:${PORT}/echo"

API_ID="$(aws apigateway create-rest-api --name "awsbox-proxy-body-${TS}" --query id --output text)"
ROOT_ID="$(aws apigateway get-resources --rest-api-id "$API_ID" --query 'items[0].id' --output text)"
RES_ID="$(aws apigateway create-resource --rest-api-id "$API_ID" --parent-id "$ROOT_ID" \
	--path-part echo --query id --output text)"
aws apigateway put-method --rest-api-id "$API_ID" --resource-id "$RES_ID" \
	--http-method POST --authorization-type NONE >/dev/null
aws apigateway put-integration --rest-api-id "$API_ID" --resource-id "$RES_ID" \
	--http-method POST --type HTTP_PROXY --integration-http-method POST \
	--uri "$BACKEND" >/dev/null
aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name prod >/dev/null

STAGE="http://127.0.0.1:4566/restapis/${API_ID}/prod/_user_request_/echo"

: >"$WORK/bodies.log"
CODE="$(curl -s -m 20 -o "$WORK/out1" -w '%{http_code}' -X POST -d "$WANT" "$STAGE")"
check "default-CT status" "200" "$CODE"
check "default-CT response" "$WANT" "$(cat "$WORK/out1")"
check "default-CT backend" "$WANT" "$(tail -n1 "$WORK/bodies.log" | tr -d '\n')"

: >"$WORK/bodies.log"
CODE="$(curl -s -m 20 -o "$WORK/out2" -w '%{http_code}' -X POST \
	-H 'Content-Type: application/json' --data-binary "$WANT" "$STAGE")"
check "json-CT status" "200" "$CODE"
check "json-CT response" "$WANT" "$(cat "$WORK/out2")"
check "json-CT backend" "$WANT" "$(tail -n1 "$WORK/bodies.log" | tr -d '\n')"

# Re-encoded form would be percent-escaped; exact match above is the sad check.
RE_ENCODED='%7B%22a%22%3A%221%22%7D='
GOT="$(cat "$WORK/out1")"
if [[ "$GOT" == "$RE_ENCODED" ]]; then
	echo "FAIL default-CT still re-encoded form body" >&2
	FAIL=1
else
	echo "ok   default-CT not re-encoded"
fi

[[ "$FAIL" -eq 0 ]] || exit 1
echo "OK: HTTP_PROXY raw body passthrough (${API_ID})"
