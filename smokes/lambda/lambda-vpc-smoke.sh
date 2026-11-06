#!/usr/bin/env bash
# VPC Lambda → host service by mapped hostname (docs/lambda-vpc.md).
# Happy: VPC function + host.docker.internal (default STACKWRANGLER_LAMBDA_DOCKER_FLAGS) → 200.
# Sad: unmapped hostname → ENOTFOUND.
# Sad: non-VPC function → mapped hostname ENOTFOUND (#187; AWS private hosts are VPC-only).
# Optional: AWSBOX_LAMBDA_SMOKE_HOST / STACKWRANGLER_LAMBDA_SMOKE_HOST=<name> also checks your mapping.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
FN="awsbox-vpc-${TS}"
FN_NOVPC="awsbox-novpc-${TS}"
ROLE_NAME="awsbox-lambda-basic"
ROLE_ARN="arn:aws:iam::000000000000:role/${ROLE_NAME}"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ZIP="$ROOT/.awsbox/lambda-vpc-${TS}.zip"
KEEP="${AWSBOX_LAMBDA_VPC_KEEP:-0}"
VPC="" SUBNET="" SG="" SERVER_PID=""

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
	rm -f "$ZIP" "$ROOT/.awsbox/lambda-vpc-${TS}.out" "$ROOT/.awsbox/lambda-novpc-${TS}.out"
	[[ "$KEEP" == "1" ]] && return 0
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$FN_NOVPC" >/dev/null 2>&1 || true
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$SUBNET" ]] && aws ec2 delete-subnet --subnet-id "$SUBNET" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Throwaway HTTP server on the host, on a free port, reachable from containers.
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1])')"
python3 -m http.server "$PORT" --bind 0.0.0.0 --directory "$ROOT/docs" >/dev/null 2>&1 &
SERVER_PID=$!

mkdir -p "$ROOT/.awsbox"
python3 - "$ZIP" <<'PY'
import sys, zipfile
code = b"""exports.handler = async (e) => {
  const out = {};
  for (const u of e.urls) {
    try { out[u] = (await fetch(u, { signal: AbortSignal.timeout(3000) })).status; }
    catch (x) { out[u] = String((x.cause && x.cause.code) || x.message); }
  }
  return out;
};
"""
with zipfile.ZipFile(sys.argv[1], "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 \
	|| aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null

VPC="$(aws ec2 create-vpc --cidr-block 10.86.0.0/16 --query Vpc.VpcId --output text)"
SUBNET="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.86.1.0/24 --query Subnet.SubnetId --output text)"
SG="$(aws ec2 create-security-group --group-name "awsbox-vpc-${TS}" --description awsbox-vpc-smoke \
	--vpc-id "$VPC" --query GroupId --output text)"

aws lambda create-function --function-name "$FN" --runtime nodejs20.x --role "$ROLE_ARN" \
	--handler index.handler --zip-file "fileb://${ZIP}" --timeout 15 \
	--vpc-config "SubnetIds=${SUBNET},SecurityGroupIds=${SG}" >/dev/null

aws lambda create-function --function-name "$FN_NOVPC" --runtime nodejs20.x --role "$ROLE_ARN" \
	--handler index.handler --zip-file "fileb://${ZIP}" --timeout 15 >/dev/null

for name in "$FN" "$FN_NOVPC"; do
	for _ in $(seq 1 60); do
		[[ "$(aws lambda get-function --function-name "$name" --query Configuration.State --output text)" == "Active" ]] && break
		sleep 2
	done
done

GOT_VPC="$(aws lambda get-function-configuration --function-name "$FN" --query VpcConfig.VpcId --output text)"
[[ "$GOT_VPC" == "$VPC" ]] || { echo "FAIL: VpcConfig not kept (got ${GOT_VPC})" >&2; exit 1; }

MAPPED="http://host.docker.internal:${PORT}/"
UNMAPPED="http://awsbox-unmapped-${TS}.internal:${PORT}/"
URLS="\"${MAPPED}\",\"${UNMAPPED}\""
EXTRA=""
SMOKE_HOST="${STACKWRANGLER_LAMBDA_SMOKE_HOST:-${AWSBOX_LAMBDA_SMOKE_HOST:-}}"
if [[ -n "$SMOKE_HOST" ]]; then
	EXTRA="http://${SMOKE_HOST}:${PORT}/"
	URLS="${URLS},\"${EXTRA}\""
fi

OUT="$ROOT/.awsbox/lambda-vpc-${TS}.out"
aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
	--payload "{\"urls\":[${URLS}]}" "$OUT" >/dev/null

python3 - "$OUT" "$MAPPED" "$UNMAPPED" "$EXTRA" <<'PY'
import json, sys
out = json.load(open(sys.argv[1]))
mapped, unmapped, extra = sys.argv[2], sys.argv[3], sys.argv[4]
ok = True
def check(label, url, want):
    global ok
    got = out.get(url)
    good = got == want
    ok &= good
    print(f"{'ok  ' if good else 'FAIL'} {label}: {url} -> {got} (want {want})")
check("happy mapped host.docker.internal", mapped, 200)
check("sad unmapped name", unmapped, "ENOTFOUND")
if extra:
    check("happy STACKWRANGLER_LAMBDA_SMOKE_HOST", extra, 200)
if not ok:
    print(
        "hint: recreate LocalEmu after changing STACKWRANGLER_LAMBDA_DOCKER_FLAGS "
        "(./bin/stackwrangler up --force)",
        file=sys.stderr,
    )
    sys.exit(1)
PY

OUT_NOVPC="$ROOT/.awsbox/lambda-novpc-${TS}.out"
aws lambda invoke --function-name "$FN_NOVPC" --cli-binary-format raw-in-base64-out \
	--payload "{\"urls\":[\"${MAPPED}\"]}" "$OUT_NOVPC" >/dev/null

python3 - "$OUT_NOVPC" "$MAPPED" <<'PY'
import json, sys
out = json.load(open(sys.argv[1]))
mapped = sys.argv[2]
got = out.get(mapped)
# ENOTFOUND is the AWS-shaped miss; ECONNREFUSED would mean the name still resolved.
ok = got == "ENOTFOUND"
print(f"{'ok  ' if ok else 'FAIL'} sad non-VPC mapped host: {mapped} -> {got} (want ENOTFOUND)")
if not ok:
    print(
        "hint: STACKWRANGLER_LAMBDA_DOCKER_FLAGS must apply only with VpcConfig (#187); "
        "recreate LocalEmu (./bin/stackwrangler up --force)",
        file=sys.stderr,
    )
    sys.exit(1)
PY

echo "OK: VPC Lambda reaches host services by mapped name; non-VPC does not (${FN})"
