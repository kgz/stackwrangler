#!/usr/bin/env bash
# ECS task AWS_ENDPOINT_URL is https + trusted CA so aws:SecureTransport=true
# (#687). Bucket DenyNonSSL must not block a correctly permissioned task role.
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
CLUSTER="awsbox-ecs-st-${TS}"
FAMILY="awsbox-ecs-st-${TS}"
ROLE="awsbox-ecs-st-${TS}"
BUCKET="awsbox-ecs-st-${TS}"
KEEP="${AWSBOX_ST_KEEP:-0}"
IMAGE="awsbox-ecs-st:${TS}"
TMP="$(mktemp -d)"
TASK_ARN=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && { rm -rf "$TMP"; return 0; }
	if [[ -n "$TASK_ARN" ]]; then
		aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" >/dev/null 2>&1 || true
	fi
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name allow-s3 >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws s3api delete-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	docker rmi "$IMAGE" >/dev/null 2>&1 || true
	rm -rf "$TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$TMP/Dockerfile" <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache aws-cli iptables iproute2 wget
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
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [f"arn:aws:s3:::{b}", f"arn:aws:s3:::{b}/*"],
  }],
}))
')" >/dev/null

aws s3 mb "s3://${BUCKET}" >/dev/null
echo "secure-transport-ok" | aws s3 cp - "s3://${BUCKET}/obj.txt"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(BUCKET="$BUCKET" python3 -c '
import json, os
b = os.environ["BUCKET"]
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyNonSSL",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [f"arn:aws:s3:::{b}", f"arn:aws:s3:::{b}/*"],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}},
  }],
}))
')" >/dev/null

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

CDEFS="$(IMAGE="$IMAGE" python3 -c '
import json, os
print(json.dumps([{
  "name": "probe",
  "image": os.environ["IMAGE"],
  "essential": True,
  "memory": 128,
  "command": ["sleep", "180"],
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

SUBNET="$(aws ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text)"
SG="$(aws ec2 describe-security-groups --query 'SecurityGroups[0].GroupId' --output text)"
[[ -n "$SUBNET" && "$SUBNET" != "None" && -n "$SG" && "$SG" != "None" ]] || {
	fail "need at least one subnet + security group (run ./smokes/compute/ecs-smoke.sh once)"
}
NET="awsvpcConfiguration={subnets=[${SUBNET}],securityGroups=[${SG}],assignPublicIp=ENABLED}"

TASK_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type FARGATE \
		--network-configuration "$NET" \
		--query 'tasks[0].taskArn' --output text
)"
[[ -n "$TASK_ARN" && "$TASK_ARN" != "None" ]] || fail "RunTask returned no taskArn"
echo "TASK_ARN=${TASK_ARN}"

NAME=""
for _ in $(seq 1 90); do
	NAME="$(docker ps --filter "label=localemu.task-arn=${TASK_ARN}" --format '{{.Names}}' | head -1)"
	[[ -n "$NAME" ]] && break
	sleep 1
done
[[ -n "$NAME" ]] || fail "task container not running"

ENV_OUT="$(docker exec "$NAME" printenv)"
echo "$ENV_OUT" | grep -qE '^AWS_ENDPOINT_URL=https://localemu\.awsbox:' \
	|| fail "expected https://localemu.awsbox endpoint: $ENV_OUT"
echo "$ENV_OUT" | grep -q '^AWS_CA_BUNDLE=/etc/awsbox/certs/ca-bundle.crt$' \
	|| fail "missing AWS_CA_BUNDLE: $ENV_OUT"
echo "$ENV_OUT" | grep -q '^NODE_EXTRA_CA_CERTS=/etc/awsbox/certs/ca.crt$' \
	|| fail "missing NODE_EXTRA_CA_CERTS: $ENV_OUT"
echo "$ENV_OUT" | grep -q '^SSL_CERT_FILE=/etc/awsbox/certs/ca-bundle.crt$' \
	|| fail "missing SSL_CERT_FILE: $ENV_OUT"

docker exec "$NAME" test -f /etc/awsbox/certs/ca.crt \
	|| fail "CA not mounted at /etc/awsbox/certs/ca.crt"
docker exec "$NAME" test -f /etc/awsbox/certs/ca-bundle.crt \
	|| fail "CA bundle not mounted"

# TLS to the emulator must verify (no -k / no insecure flag).
HEALTH="$(docker exec "$NAME" sh -c 'wget -qO- -T8 "$AWS_ENDPOINT_URL/_localemu/health"' 2>&1)" \
	|| fail "https health via AWS_ENDPOINT_URL failed: $HEALTH"
[[ -n "$HEALTH" ]] || fail "empty health body from AWS_ENDPOINT_URL"

# Same task role over plain http must hit DenyNonSSL (admin keys skip IAM).
set +e
HTTP_DENY="$(
	docker exec \
		-e AWS_DEFAULT_REGION="$REGION" \
		-e AWS_REGION="$REGION" \
		"$NAME" \
		sh -c 'env -u AWS_CA_BUNDLE -u SSL_CERT_FILE -u CURL_CA_BUNDLE -u REQUESTS_CA_BUNDLE \
			AWS_ENDPOINT_URL=http://localemu.awsbox:4566 \
			AWS_ENDPOINT_URL_S3=http://localemu.awsbox:4566 \
			aws s3 cp "s3://'"${BUCKET}"'/obj.txt" -' 2>&1
)"
HTTP_RC=$?
set -e
[[ "$HTTP_RC" -ne 0 ]] || fail "expected task http GetObject denied by SecureTransport: $HTTP_DENY"
echo "$HTTP_DENY" | grep -qiE 'AccessDenied|ExplicitDeny|Denied|Forbidden|SecureTransport|\(403\)' \
	|| fail "task http deny missing AccessDenied: $HTTP_DENY"

# Task-role GetObject over https must succeed.
set +e
GOT="$(
	docker exec \
		-e AWS_DEFAULT_REGION="$REGION" \
		-e AWS_REGION="$REGION" \
		"$NAME" \
		aws s3 cp "s3://${BUCKET}/obj.txt" - 2>&1
)"
GOT_RC=$?
set -e
[[ "$GOT_RC" -eq 0 ]] || fail "task GetObject failed (SecureTransport?): $GOT"
[[ "$GOT" == *secure-transport-ok* ]] || fail "unexpected object body: $GOT"

echo "OK: ecs secure-transport (#687)"
