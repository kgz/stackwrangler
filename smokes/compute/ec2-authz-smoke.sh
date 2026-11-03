#!/usr/bin/env bash
# Sad: deny-user ec2:RunInstances → AccessDenied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}" AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}" AWS_DEFAULT_REGION="$REGION"
TS="$(date +%s)"
USER="awsbox-ec2-deny-${TS}"
POLICY_NAME="AwsboxDenyRunInstances-${TS}"
KEEP="${AWSBOX_EC2_KEEP:-0}"
DENIED_KEY="" POLICY_ARN=""
POLICY_DOC="${TMPDIR:-/tmp}/awsbox-deny-ec2-$$.json"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }
cleanup() {
	rm -f "$POLICY_DOC"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "$DENIED_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	[[ -n "$POLICY_ARN" ]] && aws iam delete-policy --policy-arn "$POLICY_ARN" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cat >"$POLICY_DOC" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"ec2:RunInstances","Resource":"*"}]}
EOF
aws iam create-user --user-name "$USER" >/dev/null
POLICY_ARN="$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document "file://${POLICY_DOC}" --query 'Policy.Arn' --output text)"
aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
# Need a subnet if any exist; otherwise still expect deny before/at run
SUBNET="$(aws ec2 describe-subnets --query 'Subnets[0].SubnetId' --output text 2>/dev/null || echo None)"
AMI="$(aws ec2 describe-images --owners amazon --filters Name=name,Values=amzn2-ami-hvm-*-x86_64-gp2 --query 'Images[0].ImageId' --output text 2>/dev/null || echo ami-12345678)"
[[ "$AMI" == "None" || -z "$AMI" ]] && AMI="ami-12345678"
set +e
if [[ -n "$SUBNET" && "$SUBNET" != "None" ]]; then
	OUT="$(AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
		aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --subnet-id "$SUBNET" --count 1 2>&1)"
else
	OUT="$(AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
		aws ec2 run-instances --image-id "$AMI" --instance-type t3.micro --count 1 2>&1)"
fi
RC=$?
set -e
[[ "$RC" -ne 0 ]] || { echo "FAIL: run-instances succeeded" >&2; exit 1; }
echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|UnauthorizedOperation' || { echo "FAIL: $OUT" >&2; exit 1; }
echo "OK: ec2 RunInstances AccessDenied"
echo "$OUT" | head -2
