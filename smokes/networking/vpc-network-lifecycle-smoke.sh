#!/usr/bin/env bash
# Create VPC + VPC Lambda, stackwrangler down/up, recreate same CIDR, invoke (#479).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
CIDR="10.79.0.0/16"
SUBNET_CIDR="10.79.1.0/24"
FN="awsbox-vpc-net-${TS}"
ROLE_NAME="awsbox-lambda-basic"
ROLE_ARN="arn:aws:iam::000000000000:role/${ROLE_NAME}"
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
WORKDIR="${TMPDIR:-/tmp}/awsbox-vpc-net-${TS}"
ZIP="${WORKDIR}/fn.zip"
OUT="${WORKDIR}/invoke.out"
VPC="" SUBNET="" SG=""

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
	rm -rf "$WORKDIR"
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$SUBNET" ]] && aws ec2 delete-subnet --subnet-id "$SUBNET" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
}
trap cleanup EXIT

mkdir -p "$WORKDIR"
python3 - "$ZIP" <<'PY'
import sys, zipfile
code = b"""exports.handler = async () => ({ ok: true });\n"""
with zipfile.ZipFile(sys.argv[1], "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1 \
	|| aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null

# Sentinel watched by start.d/21-vpc-network-lifecycle.py (compose mounts
# ./.awsbox → /var/lib/awsbox). Forces bridge create to fail in-process.
BOOM_FLAG="$ROOT/.awsbox/vpc-bridge-boom"

install_bridge_boom() {
	mkdir -p "$ROOT/.awsbox"
	: >"$BOOM_FLAG"
	echo "ok  bridge boom flag set (${BOOM_FLAG})"
}

restore_bridge_boom() {
	rm -f "$BOOM_FLAG"
	echo "ok  bridge boom flag cleared"
}

assert_create_vpc_rolls_back() {
	local before after err
	before="$(aws ec2 describe-vpcs --query 'length(Vpcs)' --output text)"
	install_bridge_boom
	err=0
	aws ec2 create-vpc --cidr-block 10.78.0.0/16 >/tmp/awsbox-479-create-vpc.err 2>&1 || err=$?
	restore_bridge_boom
	[[ "$err" -ne 0 ]] || fail "CreateVpc succeeded while bridge create was stubbed to fail"
	grep -qiE 'InternalError|could not allocate a Docker network|Docker network' /tmp/awsbox-479-create-vpc.err \
		|| fail "CreateVpc error missing Docker-network message: $(cat /tmp/awsbox-479-create-vpc.err)"
	after="$(aws ec2 describe-vpcs --query 'length(Vpcs)' --output text)"
	[[ "$after" == "$before" ]] || fail "CreateVpc left a moto VPC after bridge failure (before=${before} after=${after})"
	echo "ok  CreateVpc fails and rolls back when bridge is not ready"
}

create_vpc_lambda() {
	VPC="$(aws ec2 create-vpc --cidr-block "$CIDR" --query Vpc.VpcId --output text)"
	[[ -n "$VPC" && "$VPC" != "None" ]] || fail "CreateVpc returned no id"
	net="localemu-vpc-${VPC}"
	docker network inspect "$net" >/dev/null 2>&1 \
		|| fail "Docker network ${net} missing after CreateVpc"
	SUBNET="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "$SUBNET_CIDR" --query Subnet.SubnetId --output text)"
	SG="$(aws ec2 create-security-group --group-name "awsbox-vpc-net-${TS}" --description awsbox-vpc-net \
		--vpc-id "$VPC" --query GroupId --output text)"
	aws lambda create-function --function-name "$FN" --runtime nodejs20.x --role "$ROLE_ARN" \
		--handler index.handler --zip-file "fileb://${ZIP}" --timeout 15 \
		--vpc-config "SubnetIds=${SUBNET},SecurityGroupIds=${SG}" >/dev/null
	for _ in $(seq 1 60); do
		[[ "$(aws lambda get-function --function-name "$FN" --query Configuration.State --output text)" == "Active" ]] && break
		sleep 2
	done
}

invoke_ok() {
	aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
		--payload '{}' "$OUT" >/dev/null
	python3 - "$OUT" <<'PY'
import json, sys
out = json.load(open(sys.argv[1]))
assert out.get("ok") is True, out
print("ok  invoke")
PY
}

echo "== phase 0: CreateVpc fails + rolls back when bridge not ready =="
assert_create_vpc_rolls_back

echo "== phase 1: create VPC ${CIDR} + VPC Lambda =="
create_vpc_lambda
invoke_ok
OLD_VPC="$VPC"
OLD_NET="localemu-vpc-${OLD_VPC}"

echo "== phase 2: stackwrangler down/up (must drop ${OLD_NET}) =="
# Leave resources dangling so down must clean Docker networks without DeleteVpc.
trap - EXIT
"$ROOT/bin/stackwrangler" down
docker network inspect "$OLD_NET" >/dev/null 2>&1 \
	&& fail "Docker network ${OLD_NET} still present after down"
"$ROOT/bin/stackwrangler" up
# Wait for IAM endpoint
for _ in $(seq 1 60); do
	aws sts get-caller-identity >/dev/null 2>&1 && break
	sleep 2
done
aws sts get-caller-identity >/dev/null

VPC="" SUBNET="" SG=""
trap cleanup EXIT

echo "== phase 3: same CIDR ${CIDR} after restart =="
create_vpc_lambda
invoke_ok

echo "OK: VPC Docker network lifecycle (#479)"
