#!/usr/bin/env bash
# DynamoDB table resource policies + aws:SourceVpce (#516).
#   * Deny unless SourceVpce matches → AccessDeniedException from the host
#   * NotAction admin ops still succeed under the same policy
#   * PrincipalArn exception in the same StringNotEquals block allows that user
#   * Two gateway endpoints A/B on different RTs: Lambda via A allows, via B denies
#   * SourceVpce list [A, B] allows both Lambdas
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
export AWS_PAGER=""
TS="$(date +%s)"
TABLE="awsbox-ddb-rp-${TS}"
USER="awsbox-ddb-rp-user-${TS}"
USER_EX="awsbox-ddb-rp-ex-${TS}"
ROLE="awsbox-ddb-rp-role-${TS}"
FN_A="awsbox-ddb-rp-a-${TS}"
FN_B="awsbox-ddb-rp-b-${TS}"
KEEP="${AWSBOX_DDB_RP_KEEP:-0}"
WORKDIR="${TMPDIR:-/tmp}/awsbox-ddb-rp-$$"
mkdir -p "$WORKDIR"
DENIED_KEY="" EX_KEY="" VPC="" SUB_A="" SUB_B="" RTB_A="" RTB_B="" SG=""
VPCE_A="" VPCE_B=""
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws lambda delete-function --function-name "$FN_A" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$FN_B" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name ddb-all >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	[[ -n "$VPCE_A" ]] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE_A" >/dev/null 2>&1 || true
	[[ -n "$VPCE_B" ]] && aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$VPCE_B" >/dev/null 2>&1 || true
	[[ -n "$SUB_A" ]] && aws ec2 delete-subnet --subnet-id "$SUB_A" >/dev/null 2>&1 || true
	[[ -n "$SUB_B" ]] && aws ec2 delete-subnet --subnet-id "$SUB_B" >/dev/null 2>&1 || true
	[[ -n "$RTB_A" && -n "$VPC" ]] && aws ec2 delete-route-table --route-table-id "$RTB_A" >/dev/null 2>&1 || true
	[[ -n "$RTB_B" && -n "$VPC" ]] && aws ec2 delete-route-table --route-table-id "$RTB_B" >/dev/null 2>&1 || true
	[[ -n "$SG" ]] && aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 || true
	[[ -n "$VPC" ]] && aws ec2 delete-vpc --vpc-id "$VPC" >/dev/null 2>&1 || true
	aws dynamodb delete-table --table-name "$TABLE" >/dev/null 2>&1 || true
	[[ -n "$DENIED_KEY" ]] && aws iam delete-access-key --user-name "$USER" --access-key-id "$DENIED_KEY" >/dev/null 2>&1 || true
	[[ -n "$EX_KEY" ]] && aws iam delete-access-key --user-name "$USER_EX" --access-key-id "$EX_KEY" >/dev/null 2>&1 || true
	aws iam delete-user-policy --user-name "$USER" --policy-name ddb-all >/dev/null 2>&1 || true
	aws iam delete-user-policy --user-name "$USER_EX" --policy-name ddb-all >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER" >/dev/null 2>&1 || true
	aws iam delete-user --user-name "$USER_EX" >/dev/null 2>&1 || true
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

expect_deny() {
	local label="$1"
	shift
	set +e
	local out rc
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || { echo "FAIL: ${label} succeeded" >&2; exit 1; }
	echo "$out" | grep -qiE 'AccessDenied' || { echo "FAIL: ${label} expected AccessDenied: ${out}" >&2; exit 1; }
	echo "$out" | grep -qi 'explicit deny in a resource-based policy' \
		|| { echo "FAIL: ${label} missing resource-based deny phrase: ${out}" >&2; exit 1; }
	echo "OK: ${label}"
}

expect_ok() {
	local label="$1"
	shift
	set +e
	local out rc
	out="$("$@" 2>&1)"
	rc=$?
	set -e
	[[ "$rc" -eq 0 ]] || { echo "FAIL: ${label}: ${out}" >&2; exit 1; }
	echo "OK: ${label}"
}

aws dynamodb create-table --table-name "$TABLE" \
	--attribute-definitions AttributeName=pk,AttributeType=S \
	--key-schema AttributeName=pk,KeyType=HASH \
	--billing-mode PAY_PER_REQUEST >/dev/null
for _ in $(seq 1 30); do
	st="$(aws dynamodb describe-table --table-name "$TABLE" --query 'Table.TableStatus' --output text 2>/dev/null || true)"
	[[ "$st" == "ACTIVE" ]] && break
	sleep 1
done
aws dynamodb put-item --table-name "$TABLE" --item '{"pk":{"S":"item-1"}}' >/dev/null
ARN="$(aws dynamodb describe-table --table-name "$TABLE" --query Table.TableArn --output text)"

# Deny unless SourceVpce matches a placeholder (host has none).
python3 - "$WORKDIR/deny-vpce.json" "$ARN" <<'PY'
import json, sys
path, arn = sys.argv[1], sys.argv[2]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Deny",
        "Principal": "*",
        "NotAction": [
            "dynamodb:PutResourcePolicy",
            "dynamodb:GetResourcePolicy",
            "dynamodb:DeleteResourcePolicy",
            "dynamodb:DeleteTable",
            "dynamodb:DescribeTable",
        ],
        "Resource": [arn, f"{arn}/index/*"],
        "Condition": {
            "StringNotEquals": {"aws:SourceVpce": "vpce-aaaaaaaaaaaaaaaaa"},
        },
    }],
}, open(path, "w"))
PY
aws dynamodb put-resource-policy --resource-arn "$ARN" --policy "file://${WORKDIR}/deny-vpce.json" >/dev/null

aws iam create-user --user-name "$USER" >/dev/null
aws iam put-user-policy --user-name "$USER" --policy-name ddb-all \
	--policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"dynamodb:*","Resource":"*"}]}' >/dev/null
KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
as_user() {
	AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" aws "$@"
}

expect_deny "GetItem denied by table resource policy (no SourceVpce)" \
	as_user dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"item-1"}}'
expect_ok "DescribeTable NotAction still allowed" \
	as_user dynamodb describe-table --table-name "$TABLE"
expect_ok "GetResourcePolicy NotAction still allowed" \
	as_user dynamodb get-resource-policy --resource-arn "$ARN"

# PrincipalArn exception: both keys must mismatch for Deny to apply.
EX_ARN="$(aws iam create-user --user-name "$USER_EX" --query User.Arn --output text)"
aws iam put-user-policy --user-name "$USER_EX" --policy-name ddb-all \
	--policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"dynamodb:*","Resource":"*"}]}' >/dev/null
EX_KEYS="$(aws iam create-access-key --user-name "$USER_EX" --output json)"
EX_KEY="$(echo "$EX_KEYS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
EX_SECRET="$(echo "$EX_KEYS" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
python3 - "$WORKDIR/deny-vpce-ex.json" "$ARN" "$EX_ARN" <<'PY'
import json, sys
path, arn, principal = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Deny",
        "Principal": "*",
        "NotAction": [
            "dynamodb:PutResourcePolicy",
            "dynamodb:GetResourcePolicy",
            "dynamodb:DeleteResourcePolicy",
            "dynamodb:DeleteTable",
            "dynamodb:DescribeTable",
        ],
        "Resource": [arn, f"{arn}/index/*"],
        "Condition": {
            "StringNotEquals": {
                "aws:SourceVpce": "vpce-aaaaaaaaaaaaaaaaa",
                "aws:PrincipalArn": principal,
            },
        },
    }],
}, open(path, "w"))
PY
aws dynamodb put-resource-policy --resource-arn "$ARN" --policy "file://${WORKDIR}/deny-vpce-ex.json" >/dev/null
as_ex() {
	AWS_ACCESS_KEY_ID="$EX_KEY" AWS_SECRET_ACCESS_KEY="$EX_SECRET" aws "$@"
}
expect_ok "PrincipalArn exception allows GetItem" \
	as_ex dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"item-1"}}'
expect_deny "other user still denied without matching PrincipalArn" \
	as_user dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"item-1"}}'

# --- Two DynamoDB gateway endpoints on different route tables ---
OCT=$((170 + RANDOM % 40))
CIDR="10.${OCT}.0.0/16"
VPC="$(aws ec2 create-vpc --cidr-block "$CIDR" --query Vpc.VpcId --output text)"
SUB_A="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "10.${OCT}.1.0/24" --query Subnet.SubnetId --output text)"
SUB_B="$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block "10.${OCT}.2.0/24" --query Subnet.SubnetId --output text)"
SG="$(aws ec2 create-security-group --group-name "awsbox-ddb-rp-${TS}" --description ddb-rp --vpc-id "$VPC" --query GroupId --output text)"
RTB_A="$(aws ec2 create-route-table --vpc-id "$VPC" --query RouteTable.RouteTableId --output text)"
RTB_B="$(aws ec2 create-route-table --vpc-id "$VPC" --query RouteTable.RouteTableId --output text)"
aws ec2 associate-route-table --route-table-id "$RTB_A" --subnet-id "$SUB_A" >/dev/null
aws ec2 associate-route-table --route-table-id "$RTB_B" --subnet-id "$SUB_B" >/dev/null
VPCE_A="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC" \
	--service-name "com.amazonaws.${REGION}.dynamodb" \
	--route-table-ids "$RTB_A" --vpc-endpoint-type Gateway \
	--query 'VpcEndpoint.VpcEndpointId' --output text)"
VPCE_B="$(aws ec2 create-vpc-endpoint --vpc-id "$VPC" \
	--service-name "com.amazonaws.${REGION}.dynamodb" \
	--route-table-ids "$RTB_B" --vpc-endpoint-type Gateway \
	--query 'VpcEndpoint.VpcEndpointId' --output text)"
[[ -n "$VPCE_A" && "$VPCE_A" != "None" && -n "$VPCE_B" && "$VPCE_B" != "None" ]] \
	|| { echo "FAIL: CreateVpcEndpoint dynamodb" >&2; exit 1; }

python3 - "$WORKDIR/deny-only-a.json" "$ARN" "$VPCE_A" <<'PY'
import json, sys
path, arn, vpce = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Deny",
        "Principal": "*",
        "NotAction": [
            "dynamodb:PutResourcePolicy",
            "dynamodb:GetResourcePolicy",
            "dynamodb:DeleteResourcePolicy",
            "dynamodb:DeleteTable",
            "dynamodb:DescribeTable",
        ],
        "Resource": [arn, f"{arn}/index/*"],
        "Condition": {"StringNotEquals": {"aws:SourceVpce": vpce}},
    }],
}, open(path, "w"))
PY
aws dynamodb put-resource-policy --resource-arn "$ARN" --policy "file://${WORKDIR}/deny-only-a.json" >/dev/null

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
aws iam put-role-policy --role-name "$ROLE" --policy-name ddb-all \
	--policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"dynamodb:*","Resource":"*"}]}' >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"

cat >"$WORKDIR/handler.py" <<PY
import boto3, os
TABLE = "${TABLE}"
def handler(event, context):
    ddb = boto3.client("dynamodb", endpoint_url=os.environ.get("AWS_ENDPOINT_URL"))
    try:
        item = ddb.get_item(TableName=TABLE, Key={"pk": {"S": "item-1"}})
        return {"ok": True, "has_item": bool(item.get("Item"))}
    except Exception as e:
        return {"ok": False, "error": str(e)}
PY
( cd "$WORKDIR" && zip -q handler.zip handler.py )

create_fn() {
	local name="$1" subnet="$2"
	aws lambda create-function --function-name "$name" --runtime python3.12 \
		--role "$ROLE_ARN" --handler handler.handler \
		--zip-file "fileb://${WORKDIR}/handler.zip" --timeout 30 \
		--vpc-config "SubnetIds=${subnet},SecurityGroupIds=${SG}" >/dev/null
	for _ in $(seq 1 60); do
		[[ "$(aws lambda get-function --function-name "$name" --query Configuration.State --output text)" == "Active" ]] && return 0
		sleep 2
	done
	echo "FAIL: lambda ${name} not Active" >&2
	exit 1
}
create_fn "$FN_A" "$SUB_A"
create_fn "$FN_B" "$SUB_B"

invoke_fn() {
	local name="$1" out="$2"
	aws lambda invoke --function-name "$name" --payload '{}' "$out" >/dev/null
	python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))' "$out"
}

OUT_A="$(invoke_fn "$FN_A" "$WORKDIR/out-a.json")"
echo "$OUT_A" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True, d' \
	|| { echo "FAIL: Lambda A (vpce A) GetItem denied: ${OUT_A}" >&2; exit 1; }
echo "OK: Lambda via gateway endpoint A allowed"

OUT_B="$(invoke_fn "$FN_B" "$WORKDIR/out-b.json")"
echo "$OUT_B" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is False and "AccessDenied" in d.get("error",""), d' \
	|| { echo "FAIL: Lambda B (vpce B) should be denied: ${OUT_B}" >&2; exit 1; }
echo "OK: Lambda via gateway endpoint B denied"

# List form: both endpoints allowed
python3 - "$WORKDIR/deny-list.json" "$ARN" "$VPCE_A" "$VPCE_B" <<'PY'
import json, sys
path, arn, a, b = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
json.dump({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Deny",
        "Principal": "*",
        "NotAction": [
            "dynamodb:PutResourcePolicy",
            "dynamodb:GetResourcePolicy",
            "dynamodb:DeleteResourcePolicy",
            "dynamodb:DeleteTable",
            "dynamodb:DescribeTable",
        ],
        "Resource": [arn, f"{arn}/index/*"],
        "Condition": {"StringNotEquals": {"aws:SourceVpce": [a, b]}},
    }],
}, open(path, "w"))
PY
aws dynamodb put-resource-policy --resource-arn "$ARN" --policy "file://${WORKDIR}/deny-list.json" >/dev/null

OUT_A="$(invoke_fn "$FN_A" "$WORKDIR/out-a2.json")"
echo "$OUT_A" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True, d' \
	|| { echo "FAIL: list SourceVpce Lambda A: ${OUT_A}" >&2; exit 1; }
OUT_B="$(invoke_fn "$FN_B" "$WORKDIR/out-b2.json")"
echo "$OUT_B" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("ok") is True, d' \
	|| { echo "FAIL: list SourceVpce Lambda B: ${OUT_B}" >&2; exit 1; }
echo "OK: SourceVpce list allows both Lambdas"

echo "OK: dynamodb resource policy + SourceVpce (#516)"
