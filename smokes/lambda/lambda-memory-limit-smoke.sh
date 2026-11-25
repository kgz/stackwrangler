#!/usr/bin/env bash
# #688: MemorySize → Docker mem_limit; over-limit → Runtime.OutOfMemory;
# REPORT Max Memory Used from cgroup peak (not a fixed Memory Size echo).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

TS="$(date +%s)"
ROLE_NAME="awsbox-lambda-mem-${TS}"
ROLE_ARN="arn:aws:iam::000000000000:role/${ROLE_NAME}"
SMALL_FN="awsbox-mem-small-${TS}"
OOM_FN="awsbox-mem-oom-${TS}"
ZIP_DIR="$ROOT/.awsbox/lambda-mem-${TS}"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
	aws lambda delete-function --function-name "$SMALL_FN" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$OOM_FN" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
	rm -rf "$ZIP_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$ZIP_DIR"
python3 - <<'PY' "$ZIP_DIR"
import sys, zipfile
from pathlib import Path
d = Path(sys.argv[1])
small = b"""exports.handler = async () => ({ ok: true });\n"""
oom = b"""exports.handler = async () => {
  const chunks = [];
  for (let i = 0; i < 40; i++) {
    const buf = Buffer.alloc(8 * 1024 * 1024, i & 0xff);
    chunks.push(buf);
  }
  return { ok: true, n: chunks.length };
};
"""
with zipfile.ZipFile(d / "small.zip", "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", small)
with zipfile.ZipFile(d / "oom.zip", "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", oom)
PY

aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null

create_fn() { # name zip memory timeout
	aws lambda create-function \
		--function-name "$1" \
		--runtime nodejs18.x \
		--role "$ROLE_ARN" \
		--handler index.handler \
		--memory-size "$3" \
		--timeout "$4" \
		--zip-file "fileb://${ZIP_DIR}/$2" >/dev/null
}

wait_active() {
	local fn="$1" state=""
	for _ in $(seq 1 60); do
		state="$(
			aws lambda get-function --function-name "$fn" \
				--query 'Configuration.State' --output text 2>/dev/null || echo Pending
		)"
		[[ "$state" == "Active" ]] && return 0
		sleep 2
	done
	fail "$fn never Active (state=${state})"
}

create_fn "$SMALL_FN" small.zip 256 10
create_fn "$OOM_FN" oom.zip 128 30
wait_active "$SMALL_FN"
wait_active "$OOM_FN"

# --- mem_limit applied on HostConfig ---
find_lambda_container() {
	local fn="$1" name=""
	for _ in $(seq 1 60); do
		name="$(
			docker ps -a --filter "name=lambda-${fn}" --format '{{.Names}}' 2>/dev/null | head -1
		)"
		# LocalEmu names: <main>-lambda-<sanitized-fn>-<id>
		if [[ -z "$name" ]]; then
			name="$(
				docker ps -a --format '{{.Names}}' 2>/dev/null \
					| grep -i "lambda-.*${fn}" | head -1 || true
			)"
		fi
		if [[ -n "$name" ]]; then
			printf '%s' "$name"
			return 0
		fi
		sleep 1
	done
	return 1
}

# Cold-start small fn so its container exists
SMALL_OUT="$ZIP_DIR/small-out.json"
aws lambda invoke --function-name "$SMALL_FN" \
	--cli-binary-format raw-in-base64-out \
	--log-type Tail \
	--payload '{}' \
	"$SMALL_OUT" >"$ZIP_DIR/small-invoke.json"

SMALL_CTR="$(find_lambda_container "$SMALL_FN")" \
	|| fail "no docker container for ${SMALL_FN}"
MEM_BYTES="$(docker inspect "$SMALL_CTR" --format '{{.HostConfig.Memory}}')"
# 256 MiB
[[ "$MEM_BYTES" == "268435456" ]] \
	|| fail "HostConfig.Memory=${MEM_BYTES} want 268435456 (256m) on ${SMALL_CTR}"
echo "OK: MemorySize=256 → docker Memory=${MEM_BYTES}"

# --- Max Memory Used from cgroup peak (not fixed = Memory Size) ---
LOG_B64="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("LogResult") or "")' "$ZIP_DIR/small-invoke.json")"
[[ -n "$LOG_B64" ]] || fail "missing LogResult on small invoke"
REPORT="$(printf '%s' "$LOG_B64" | base64 -d 2>/dev/null || printf '%s' "$LOG_B64" | base64 --decode)"
echo "$REPORT" | grep -q 'REPORT RequestId:' || fail "no REPORT in LogResult: $REPORT"
MAX_USED="$(echo "$REPORT" | sed -n 's/.*Max Memory Used: \([0-9][0-9]*\) MB.*/\1/p' | tail -1)"
[[ -n "$MAX_USED" ]] || fail "no Max Memory Used in REPORT: $REPORT"
[[ "$MAX_USED" -gt 0 ]] || fail "Max Memory Used=${MAX_USED} want >0"
[[ "$MAX_USED" -lt 256 ]] || fail "Max Memory Used=${MAX_USED} still looks fixed at Memory Size (256)"
echo "OK: Max Memory Used=${MAX_USED} MB (< 256, from cgroup peak)"

# --- over MemorySize → Runtime.OutOfMemory ---
OOM_OUT="$ZIP_DIR/oom-out.json"
set +e
aws lambda invoke --function-name "$OOM_FN" \
	--cli-binary-format raw-in-base64-out \
	--log-type Tail \
	--payload '{}' \
	"$OOM_OUT" >"$ZIP_DIR/oom-invoke.json" 2>"$ZIP_DIR/oom-invoke.err"
OOM_RC=$?
set -e

OOM_META="$(cat "$ZIP_DIR/oom-invoke.json" 2>/dev/null || true)"
OOM_BODY="$(cat "$OOM_OUT" 2>/dev/null || true)"
FUNC_ERR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("FunctionError") or "")' "$ZIP_DIR/oom-invoke.json" 2>/dev/null || true)"

echo "OOM invoke rc=${OOM_RC} FunctionError=${FUNC_ERR} body=${OOM_BODY}"

[[ "$FUNC_ERR" == "Unhandled" ]] || fail "OOM FunctionError=${FUNC_ERR} want Unhandled (meta=${OOM_META})"
echo "$OOM_BODY" | grep -q 'Runtime.OutOfMemory' \
	|| fail "OOM payload missing Runtime.OutOfMemory: ${OOM_BODY}"

OOM_CTR="$(find_lambda_container "$OOM_FN" || true)"
if [[ -n "$OOM_CTR" ]]; then
	OOM_MEM="$(docker inspect "$OOM_CTR" --format '{{.HostConfig.Memory}}' 2>/dev/null || echo "")"
	[[ "$OOM_MEM" == "134217728" ]] || fail "OOM fn Memory=${OOM_MEM} want 134217728"
	OOMK="$(docker inspect "$OOM_CTR" --format '{{.State.OOMKilled}}' 2>/dev/null || echo "")"
	# Container may already be removed; OOMKilled true is best-effort proof.
	echo "OOM container Memory=${OOM_MEM} OOMKilled=${OOMK}"
fi

OOM_LOG_B64="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("LogResult") or "")' "$ZIP_DIR/oom-invoke.json" 2>/dev/null || true)"
if [[ -n "$OOM_LOG_B64" ]]; then
	OOM_REPORT="$(printf '%s' "$OOM_LOG_B64" | base64 -d 2>/dev/null || printf '%s' "$OOM_LOG_B64" | base64 --decode)"
	echo "$OOM_REPORT" | grep -q 'Runtime.OutOfMemory\|Max Memory Used:' \
		|| fail "OOM LogResult missing REPORT/OOM: $OOM_REPORT"
	echo "OK: OOM REPORT present"
fi

echo "OK: lambda memory-limit smoke (#688)"
