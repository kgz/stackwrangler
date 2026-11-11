#!/usr/bin/env bash
# ECS awsvpc + tight SG: task-role creds and AWS_ENDPOINT_URL must still work
# when the VPC has endpoints (#686). Link-local creds stay reachable without
# widening egress; injected endpoint URL is treated as VPCE HTTPS stand-in.
#
# Happy: private subnet, egress 443 to VPC CIDR (+ S3 prefix list when present),
#   interface STS + S3 gateway endpoints → creds URI + S3 GetObject succeed.
# Sad: same SG, no VPC endpoints → creds still work; AWS_ENDPOINT_URL times out.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
CLUSTER="awsbox-ecs-sgcred-${TS}"
FAMILY="awsbox-ecs-sgcred-${TS}"
ROLE="awsbox-ecs-sgcred-${TS}"
BUCKET="awsbox-ecs-sgcred-${TS}"
KEEP="${AWSBOX_SGCRED_KEEP:-0}"
IMAGE="awsbox-ecs-sgcred:${TS}"
TMP="$(mktemp -d)"
FAILS=0
TASK_OK="" TASK_SAD=""
VPC_OK="" VPC_SAD="" SUB_OK="" SUB_SAD="" SG_OK="" SG_SAD=""
RTB_OK="" VPCE_IDS=()

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

ok() { echo "ok  $*"; }
bad() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
	[[ "$KEEP" == "1" ]] && { rm -rf "$TMP"; return 0; }
	for t in "$TASK_OK" "$TASK_SAD"; do
		[[ -n "$t" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$t" >/dev/null 2>&1 || true
	done
	for epid in "${VPCE_IDS[@]:-}"; do
		[[ -n "$epid" ]] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$epid" >/dev/null 2>&1 || true
	done
	sleep 1
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name allow-s3 >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	[[ -n "$SG_OK" ]] && aws ec2 delete-security-group --group-id "$SG_OK" >/dev/null 2>&1 || true
	[[ -n "$SG_SAD" ]] && aws ec2 delete-security-group --group-id "$SG_SAD" >/dev/null 2>&1 || true
	[[ -n "$SUB_OK" ]] && aws ec2 delete-subnet --subnet-id "$SUB_OK" >/dev/null 2>&1 || true
	[[ -n "$SUB_SAD" ]] && aws ec2 delete-subnet --subnet-id "$SUB_SAD" >/dev/null 2>&1 || true
	[[ -n "$VPC_OK" ]] && aws ec2 delete-vpc --vpc-id "$VPC_OK" >/dev/null 2>&1 || true
	[[ -n "$VPC_SAD" ]] && aws ec2 delete-vpc --vpc-id "$VPC_SAD" >/dev/null 2>&1 || true
	docker rmi "$IMAGE" >/dev/null 2>&1 || true
	rm -rf "$TMP"
}
trap cleanup EXIT

cat >"$TMP/Dockerfile" <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache aws-cli iptables iproute2 wget curl
EOF
docker build -t "$IMAGE" "$TMP" >/dev/null

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name allow-s3 --policy-document "$(BUCKET="$BUCKET" python3 -c '
import json, os
b = os.environ["BUCKET"]
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket", "s3:PutObject"],
    "Resource": [f"arn:aws:s3:::{b}", f"arn:aws:s3:::{b}/*"],
  }],
}))
')" >/dev/null

aws s3 mb "s3://${BUCKET}" >/dev/null
echo "sg-creds-ok" | aws s3 cp - "s3://${BUCKET}/obj.txt"

mk_vpc() {
	local oct="$1"
	aws ec2 create-vpc --cidr-block "10.${oct}.0.0/16" --query Vpc.VpcId --output text
}

mk_subnet() {
	local vpc="$1" oct="$2"
	aws ec2 create-subnet --vpc-id "$vpc" --cidr-block "10.${oct}.1.0/24" --query Subnet.SubnetId --output text
}

# Tight egress matching the issue: 443 to VPC CIDR (+ S3 PL), 3306/8080 to VPC.
mk_tight_sg() {
	local vpc="$1" name="$2" cidr="$3"
	local sg pl_s3
	sg="$(aws ec2 create-security-group \
		--group-name "$name" --description "ecs sg creds #686" --vpc-id "$vpc" \
		--query GroupId --output text)"
	aws ec2 revoke-security-group-egress --group-id "$sg" --ip-permissions \
		'[{"IpProtocol":"-1","IpRanges":[{"CidrIp":"0.0.0.0/0"}]}]' >/dev/null 2>&1 || true
	aws ec2 authorize-security-group-egress --group-id "$sg" --ip-permissions \
		"[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"IpRanges\":[{\"CidrIp\":\"${cidr}\"}]},
		  {\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"IpRanges\":[{\"CidrIp\":\"${cidr}\"}]},
		  {\"IpProtocol\":\"tcp\",\"FromPort\":8080,\"ToPort\":8080,\"IpRanges\":[{\"CidrIp\":\"${cidr}\"}]}]" \
		>/dev/null
	pl_s3="$(aws ec2 describe-managed-prefix-lists \
		--query "PrefixLists[?PrefixListName==\`com.amazonaws.${REGION}.s3\`].PrefixListId | [0]" \
		--output text 2>/dev/null || true)"
	if [[ -n "$pl_s3" && "$pl_s3" != "None" ]]; then
		aws ec2 authorize-security-group-egress --group-id "$sg" --ip-permissions \
			"[{\"IpProtocol\":\"tcp\",\"FromPort\":443,\"ToPort\":443,\"PrefixListIds\":[{\"PrefixListId\":\"${pl_s3}\"}]}]" \
			>/dev/null || true
	fi
	printf '%s' "$sg"
}

OCT_OK=$((110 + RANDOM % 40))
OCT_SAD=$((150 + RANDOM % 40))
VPC_OK="$(mk_vpc "$OCT_OK")"
VPC_SAD="$(mk_vpc "$OCT_SAD")"
SUB_OK="$(mk_subnet "$VPC_OK" "$OCT_OK")"
SUB_SAD="$(mk_subnet "$VPC_SAD" "$OCT_SAD")"
SG_OK="$(mk_tight_sg "$VPC_OK" "ecs-sgcred-ok-${TS}" "10.${OCT_OK}.0.0/16")"
SG_SAD="$(mk_tight_sg "$VPC_SAD" "ecs-sgcred-sad-${TS}" "10.${OCT_SAD}.0.0/16")"

RTB_OK="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_OK" \
	--query 'RouteTables[0].RouteTableId' --output text)"

# Interface STS + S3 gateway — enough for stand-in exemption when SG allows :443.
EP_STS="$(aws ec2 create-vpc-endpoint \
	--vpc-id "$VPC_OK" \
	--vpc-endpoint-type Interface \
	--service-name "com.amazonaws.${REGION}.sts" \
	--subnet-ids "$SUB_OK" \
	--security-group-ids "$SG_OK" \
	--private-dns-enabled \
	--query 'VpcEndpoint.VpcEndpointId' --output text)"
[[ -n "$EP_STS" && "$EP_STS" != "None" ]] || fail "CreateVpcEndpoint STS"
VPCE_IDS+=("$EP_STS")

EP_S3="$(aws ec2 create-vpc-endpoint \
	--vpc-id "$VPC_OK" \
	--service-name "com.amazonaws.${REGION}.s3" \
	--route-table-ids "$RTB_OK" \
	--vpc-endpoint-type Gateway \
	--query 'VpcEndpoint.VpcEndpointId' --output text)"
[[ -n "$EP_S3" && "$EP_S3" != "None" ]] || fail "CreateVpcEndpoint S3 gateway"
VPCE_IDS+=("$EP_S3")

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

CDEFS="$(IMAGE="$IMAGE" python3 -c '
import json, os
print(json.dumps([{
  "name": "probe",
  "image": os.environ["IMAGE"],
  "essential": True,
  "memory": 128,
  "command": ["sleep", "300"],
}]))
')"

aws ecs register-task-definition \
	--family "$FAMILY" \
	--requires-compatibilities FARGATE \
	--network-mode awsvpc \
	--cpu 256 --memory 512 \
	--task-role-arn "$ROLE_ARN" \
	--container-definitions "$CDEFS" \
	>/dev/null

run_task() {
	local sub="$1" sg="$2"
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type FARGATE \
		--network-configuration "awsvpcConfiguration={subnets=[${sub}],securityGroups=[${sg}],assignPublicIp=DISABLED}" \
		--query 'tasks[0].taskArn' --output text
}

wait_ctr() {
	local arn="$1" name=""
	for _ in $(seq 1 90); do
		name="$(docker ps --filter "label=localemu.task-arn=${arn}" --format '{{.Names}}' | head -1 || true)"
		if [[ -n "$name" ]] && docker exec "$name" true >/dev/null 2>&1; then
			printf '%s' "$name"
			return 0
		fi
		sleep 1
	done
	return 1
}

probe_creds() {
	local name="$1"
	local rel body
	rel="$(docker exec "$name" printenv AWS_CONTAINER_CREDENTIALS_RELATIVE_URI)"
	[[ -n "$rel" ]] || return 1
	body="$(docker exec "$name" wget -qO- --timeout=5 "http://169.254.170.2${rel}" 2>/dev/null || true)"
	echo "$body" | grep -q AccessKeyId
}

probe_endpoint() {
	local name="$1"
	# curl --max-time only — busybox wget ignores connect timeout when SG DROPs SYN.
	local out
	out="$(docker exec "$name" sh -c \
		'curl -fsS --max-time 4 "${AWS_ENDPOINT_URL}/_localemu/health"' \
		2>/dev/null || true)"
	echo "$out" | grep -q '"services"'
}

TASK_OK="$(run_task "$SUB_OK" "$SG_OK")"
[[ -n "$TASK_OK" && "$TASK_OK" != "None" ]] || fail "RunTask (with endpoints)"
CTR_OK="$(wait_ctr "$TASK_OK")" || fail "task container (with endpoints) not running"
echo "happy task=${TASK_OK##*/} ctr=${CTR_OK}"

# Confirm tight SG is installed (no blanket 0.0.0.0/0 ACCEPT on SG_OUT).
SG_OUT="$(docker exec "$CTR_OK" iptables -S SG_OUT 2>/dev/null || true)"
echo "$SG_OUT" | grep -q -- '-A SG_OUT -j DROP' \
	&& ok "SG_OUT default DROP present" \
	|| bad "SG_OUT missing default DROP: ${SG_OUT:0:200}"
if echo "$SG_OUT" | grep -qE -- '-A SG_OUT -d 0\.0\.0\.0/0 -j ACCEPT'; then
	bad "SG_OUT still allows all egress to 0.0.0.0/0"
else
	ok "SG_OUT has no allow-all egress"
fi
echo "$SG_OUT" | grep -q '169.254.170.2' \
	&& ok "SG_OUT exempts link-local task creds" \
	|| bad "SG_OUT missing 169.254.170.2 ACCEPT: ${SG_OUT:0:300}"

if probe_creds "$CTR_OK"; then
	ok "task-role credentials via 169.254.170.2 under tight SG (with VPCEs)"
else
	bad "credentials fetch failed under tight SG (with VPCEs)"
fi

EMU="$(docker exec "$CTR_OK" printenv AWS_ENDPOINT_URL || true)"
[[ -n "$EMU" ]] || bad "AWS_ENDPOINT_URL unset in task"
if probe_endpoint "$CTR_OK"; then
	ok "AWS_ENDPOINT_URL reachable under tight SG when VPC has endpoints (${EMU})"
else
	bad "AWS_ENDPOINT_URL not reachable with VPCEs under tight SG (${EMU})"
	docker exec "$CTR_OK" iptables -S SG_OUT >&2 || true
fi

# S3 GetObject via task role proves SDK + creds + endpoint together.
S3_OUT="$(
	docker exec \
		-e AWS_DEFAULT_REGION="$REGION" \
		-e AWS_REGION="$REGION" \
		"$CTR_OK" \
		aws s3 cp "s3://${BUCKET}/obj.txt" - 2>&1 || true
)"
echo "$S3_OUT" | grep -q 'sg-creds-ok' \
	&& ok "task-role S3 GetObject via injected endpoint under tight SG" \
	|| bad "task-role S3 failed: ${S3_OUT:0:200}"

# --- Sad: identical tight SG, no VPC endpoints ---
TASK_SAD="$(run_task "$SUB_SAD" "$SG_SAD")"
[[ -n "$TASK_SAD" && "$TASK_SAD" != "None" ]] || fail "RunTask (no endpoints)"
CTR_SAD="$(wait_ctr "$TASK_SAD")" || fail "task container (no endpoints) not running"
echo "sad task=${TASK_SAD##*/} ctr=${CTR_SAD}"

if probe_creds "$CTR_SAD"; then
	ok "credentials still work under tight SG without VPCEs"
else
	bad "credentials failed without VPCEs (link-local must stay exempt)"
fi

if probe_endpoint "$CTR_SAD"; then
	bad "AWS_ENDPOINT_URL unexpectedly reachable without VPCEs (SG should drop)"
else
	ok "AWS_ENDPOINT_URL timed out without VPCEs under tight SG"
fi

if [[ "$FAILS" -gt 0 ]]; then
	echo "FAIL: ecs-sg-creds-endpoint-smoke (${FAILS} assertion(s) failed)" >&2
	exit 1
fi
echo "OK: ecs-sg-creds-endpoint-smoke"
