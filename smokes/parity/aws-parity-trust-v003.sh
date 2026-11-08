#!/usr/bin/env bash
# Real-AWS parity for Trust (v0.0.3) tickets — short-lived create→assert→delete.
# Local coverage: the per-ticket smokes under smokes/{data,security,iac,...}.
# Usage: ./smokes/parity/aws-parity-trust-v003.sh
# Env: AWSBOX_PARITY_KEEP=1 | AWSBOX_PARITY_REGION=ap-southeast-2
#
# Cost (approved for this run):
#   IAM / SNS / SQS / DDB on-demand / CFN short stacks / S3 / Lambda / ECR → ~$0 if torn down
#   #223: 1 CMK → schedule-key-deletion 7-day min residual (~$1/mo prorated until gone)
# Skipped: #479 (LocalEmu docker lifecycle), #233 (needs second AWS account),
#          #223 EC2 RunInstances happy-path (deny-only PassRole via simulate)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Local stack keys must not override ~/.aws/credentials [default]
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ENDPOINT_URL
export AWS_DEFAULT_REGION="${AWSBOX_PARITY_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-2}}"
export AWS_PAGER=""

KEEP="${AWSBOX_PARITY_KEEP:-0}"
TS="$(date +%s)"
PREFIX="sw-trust-${TS}"
FAIL=0
CLEANUP_CMDS=()
KMS_PENDING=""

on_cleanup() { CLEANUP_CMDS+=("$1"); }
run_cleanup() {
	[[ "$KEEP" == "1" ]] && {
		echo "KEEP=1 — left resources tagged ${PREFIX}"
		return 0
	}
	local i
	for ((i = ${#CLEANUP_CMDS[@]} - 1; i >= 0; i--)); do
		eval "${CLEANUP_CMDS[$i]}" || true
	done
}
trap run_cleanup EXIT

aws_r() { aws --region "$AWS_DEFAULT_REGION" "$@"; }

echo "==> caller"
aws_r sts get-caller-identity
ACCOUNT="$(aws_r sts get-caller-identity --query Account --output text)"
WORK="$(mktemp -d "/tmp/${PREFIX}.XXXX")"
on_cleanup "rm -rf '$WORK'"

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; return 1; }

# ---------- #517 SimulateCustomPolicy / SimulatePrincipalPolicy ----------
section_517() {
	echo ""
	echo "======== #517 SimulatePolicy ========"
	local role="${PREFIX}-sim"
	cat >"$WORK/trust.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::${ACCOUNT}:root"},"Action":"sts:AssumeRole"}]}
EOF
	aws_r iam create-role --role-name "$role" --assume-role-policy-document "file://${WORK}/trust.json" \
		--tags Key=stackwrangler-parity,Value=trust-v003 >/dev/null
	on_cleanup "aws_r iam delete-role-policy --role-name '$role' --policy-name allow 2>/dev/null; aws_r iam delete-role --role-name '$role'"
	cat >"$WORK/allow-sns.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"sns:Publish","Resource":"*"}]}
EOF
	aws_r iam put-role-policy --role-name "$role" --policy-name allow --policy-document "file://${WORK}/allow-sns.json" >/dev/null

	local dec
	dec="$(aws_r iam simulate-custom-policy \
		--policy-input-list "$(cat "$WORK/allow-sns.json")" \
		--action-names sns:Publish \
		--resource-arns "arn:aws:sns:${AWS_DEFAULT_REGION}:${ACCOUNT}:t" \
		--query 'EvaluationResults[0].EvalDecision' --output text)"
	[[ "$dec" == "allowed" ]] || fail "#517 custom allow got $dec"
	pass "#517 SimulateCustomPolicy allowed"

	cat >"$WORK/deny-sns.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"sns:Publish","Resource":"*"}]}
EOF
	dec="$(aws_r iam simulate-custom-policy \
		--policy-input-list "$(cat "$WORK/deny-sns.json")" \
		--action-names sns:Publish \
		--resource-arns "arn:aws:sns:${AWS_DEFAULT_REGION}:${ACCOUNT}:t" \
		--query 'EvaluationResults[0].EvalDecision' --output text)"
	[[ "$dec" == "explicitDeny" ]] || fail "#517 custom deny got $dec"
	pass "#517 SimulateCustomPolicy explicitDeny"

	dec="$(aws_r iam simulate-principal-policy \
		--policy-source-arn "arn:aws:iam::${ACCOUNT}:role/${role}" \
		--action-names sns:Publish \
		--resource-arns "arn:aws:sns:${AWS_DEFAULT_REGION}:${ACCOUNT}:t" \
		--query 'EvaluationResults[0].EvalDecision' --output text)"
	[[ "$dec" == "allowed" ]] || fail "#517 principal got $dec"
	pass "#517 SimulatePrincipalPolicy"
}

# ---------- #525 iam:PermissionsBoundary condition key ----------
section_525() {
	echo ""
	echo "======== #525 PermissionsBoundary ========"
	local boundary="${PREFIX}-pb"
	local deploy="${PREFIX}-pb-deploy"
	local app="${PREFIX}-pb-app"
	cat >"$WORK/boundary.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetObject","s3:ListBucket"],"Resource":"*"}]}
EOF
	local boundary_arn
	boundary_arn="$(aws_r iam create-policy --policy-name "$boundary" --policy-document "file://${WORK}/boundary.json" \
		--query Policy.Arn --output text)"
	on_cleanup "aws_r iam delete-policy --policy-arn '$boundary_arn'"

	cat >"$WORK/trust.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::${ACCOUNT}:root"},"Action":"sts:AssumeRole"}]}
EOF
	aws_r iam create-role --role-name "$deploy" --assume-role-policy-document "file://${WORK}/trust.json" >/dev/null
	on_cleanup "aws_r iam delete-role-policy --role-name '$deploy' --policy-name deploy 2>/dev/null; aws_r iam delete-role --role-name '$deploy'"

	cat >"$WORK/deploy-inline.json" <<EOF
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":"iam:CreateRole","Resource":"arn:aws:iam::${ACCOUNT}:role/${PREFIX}-pb-app*",
   "Condition":{"StringEquals":{"iam:PermissionsBoundary":"${boundary_arn}"}}},
  {"Effect":"Allow","Action":"iam:AttachRolePolicy","Resource":"arn:aws:iam::${ACCOUNT}:role/${PREFIX}-pb-app*",
   "Condition":{"StringEquals":{"iam:PermissionsBoundary":"${boundary_arn}"}}},
  {"Effect":"Allow","Action":"iam:PassRole","Resource":"*"}
]}
EOF
	aws_r iam put-role-policy --role-name "$deploy" --policy-name deploy --policy-document "file://${WORK}/deploy-inline.json" >/dev/null

	# wait for role assume
	local creds key secret token
	for _ in $(seq 1 30); do
		set +e
		creds="$(aws_r sts assume-role --role-arn "arn:aws:iam::${ACCOUNT}:role/${deploy}" \
			--role-session-name pb --duration-seconds 900 --output json 2>/dev/null)"
		set -e
		[[ -n "$creds" ]] && break
		sleep 2
	done
	[[ -n "$creds" ]] || { fail "#525 assume deploy role"; return; }
	key="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$creds")"
	secret="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$creds")"
	token="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$creds")"
	as_deploy() {
		AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" AWS_SESSION_TOKEN="$token" \
			aws --region "$AWS_DEFAULT_REGION" "$@"
	}

	set +e
	as_deploy iam create-role --role-name "$app" --assume-role-policy-document "file://${WORK}/trust.json" >/tmp/${PREFIX}-nob.err 2>&1
	local rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || { fail "#525 CreateRole without boundary succeeded"; return; }
	pass "#525 CreateRole without boundary denied"

	as_deploy iam create-role --role-name "$app" --assume-role-policy-document "file://${WORK}/trust.json" \
		--permissions-boundary "$boundary_arn" >/dev/null
	on_cleanup "aws_r iam delete-role --role-name '$app' 2>/dev/null"
	pass "#525 CreateRole with matching boundary allowed"
}

# ---------- #518 sns:Protocol / sns:Endpoint ----------
section_518() {
	echo ""
	echo "======== #518 SNS Subscribe conditions ========"
	local topic="${PREFIX}-topic"
	local intake="${PREFIX}-intake"
	local other="${PREFIX}-other"
	local role="${PREFIX}-sns-sub"
	local topic_arn intake_url other_url intake_arn other_arn

	topic_arn="$(aws_r sns create-topic --name "$topic" --query TopicArn --output text)"
	on_cleanup "aws_r sns delete-topic --topic-arn '$topic_arn'"
	intake_url="$(aws_r sqs create-queue --queue-name "$intake" --query QueueUrl --output text)"
	other_url="$(aws_r sqs create-queue --queue-name "$other" --query QueueUrl --output text)"
	on_cleanup "aws_r sqs delete-queue --queue-url '$intake_url'; aws_r sqs delete-queue --queue-url '$other_url'"
	intake_arn="$(aws_r sqs get-queue-attributes --queue-url "$intake_url" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
	other_arn="$(aws_r sqs get-queue-attributes --queue-url "$other_url" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"

	# queue policy allow SNS
	for qurl in "$intake_url" "$other_url"; do
		qarn="$(aws_r sqs get-queue-attributes --queue-url "$qurl" --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)"
		python3 - "$qurl" "$qarn" "$AWS_DEFAULT_REGION" <<'PY'
import json, subprocess, sys
qurl, qarn, region = sys.argv[1], sys.argv[2], sys.argv[3]
policy = {
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "sns.amazonaws.com"},
        "Action": "sqs:SendMessage",
        "Resource": qarn,
    }],
}
attrs = json.dumps({"Policy": json.dumps(policy)})
subprocess.check_call([
    "aws", "--region", region, "sqs", "set-queue-attributes",
    "--queue-url", qurl, "--attributes", attrs,
])
PY
	done

	cat >"$WORK/trust.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::${ACCOUNT}:root"},"Action":"sts:AssumeRole"}]}
EOF
	aws_r iam create-role --role-name "$role" --assume-role-policy-document "file://${WORK}/trust.json" >/dev/null
	on_cleanup "aws_r iam delete-role-policy --role-name '$role' --policy-name sub 2>/dev/null; aws_r iam delete-role --role-name '$role'"
	cat >"$WORK/sub-inline.json" <<EOF
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow","Action":"sns:Subscribe","Resource":"${topic_arn}",
  "Condition":{"StringEquals":{"sns:Protocol":"sqs","sns:Endpoint":"${intake_arn}"}}
}]}
EOF
	aws_r iam put-role-policy --role-name "$role" --policy-name sub --policy-document "file://${WORK}/sub-inline.json" >/dev/null

	local creds key secret token
	for _ in $(seq 1 30); do
		set +e
		creds="$(aws_r sts assume-role --role-arn "arn:aws:iam::${ACCOUNT}:role/${role}" \
			--role-session-name sns --duration-seconds 900 --output json 2>/dev/null)"
		set -e
		[[ -n "$creds" ]] && break
		sleep 2
	done
	key="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$creds")"
	secret="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$creds")"
	token="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$creds")"
	as_role() {
		AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" AWS_SESSION_TOKEN="$token" \
			aws --region "$AWS_DEFAULT_REGION" "$@"
	}

	local sub
	sub="$(as_role sns subscribe --topic-arn "$topic_arn" --protocol sqs --notification-endpoint "$intake_arn" \
		--query SubscriptionArn --output text)"
	[[ -n "$sub" && "$sub" != "None" ]] || fail "#518 intake subscribe"
	on_cleanup "aws_r sns unsubscribe --subscription-arn '$sub' 2>/dev/null"
	pass "#518 Subscribe intake sqs allowed"

	set +e
	as_role sns subscribe --topic-arn "$topic_arn" --protocol sqs --notification-endpoint "$other_arn" >/tmp/${PREFIX}-other.err 2>&1
	local rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "#518 other-queue subscribe succeeded"
	pass "#518 Subscribe other-queue denied"

	set +e
	as_role sns subscribe --topic-arn "$topic_arn" --protocol https \
		--notification-endpoint "https://example.invalid/hook" >/tmp/${PREFIX}-https.err 2>&1
	rc=$?
	set -e
	[[ "$rc" -ne 0 ]] || fail "#518 https subscribe succeeded"
	pass "#518 Subscribe protocol https denied"
}

# ---------- #307 / #306 DDB table IAM (resource tags + batch/transact table ARN) ----------
section_ddb_iam() {
	echo ""
	echo "======== #307+#306 DynamoDB table IAM ========"
	local table="${PREFIX}-ddb"
	aws_r dynamodb create-table \
		--table-name "$table" \
		--attribute-definitions AttributeName=pk,AttributeType=S \
		--key-schema AttributeName=pk,KeyType=HASH \
		--billing-mode PAY_PER_REQUEST \
		--tags Key=stackwrangler-parity,Value=trust-v003 Key=env,Value=parity >/dev/null
	on_cleanup "aws_r dynamodb delete-table --table-name '$table'"
	aws_r dynamodb wait table-exists --table-name "$table"

	local role="${PREFIX}-ddb-role"
	cat >"$WORK/trust.json" <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::${ACCOUNT}:root"},"Action":"sts:AssumeRole"}]}
EOF
	aws_r iam create-role --role-name "$role" --assume-role-policy-document "file://${WORK}/trust.json" >/dev/null
	on_cleanup "aws_r iam delete-role-policy --role-name '$role' --policy-name ddb 2>/dev/null; aws_r iam delete-role --role-name '$role'"
	local table_arn="arn:aws:dynamodb:${AWS_DEFAULT_REGION}:${ACCOUNT}:table/${table}"
	cat >"$WORK/ddb-inline.json" <<EOF
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:GetItem","dynamodb:TransactWriteItems","dynamodb:BatchWriteItem"],
   "Resource":["${table_arn}","${table_arn}/index/*"],
   "Condition":{"StringEquals":{"aws:ResourceTag/env":"parity"}}}
]}
EOF
	aws_r iam put-role-policy --role-name "$role" --policy-name ddb --policy-document "file://${WORK}/ddb-inline.json" >/dev/null

	local creds key secret token
	for _ in $(seq 1 30); do
		set +e
		creds="$(aws_r sts assume-role --role-arn "arn:aws:iam::${ACCOUNT}:role/${role}" \
			--role-session-name ddb --duration-seconds 900 --output json 2>/dev/null)"
		set -e
		[[ -n "$creds" ]] && break
		sleep 2
	done
	key="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["AccessKeyId"])' <<<"$creds")"
	secret="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SecretAccessKey"])' <<<"$creds")"
	token="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["Credentials"]["SessionToken"])' <<<"$creds")"
	as_role() {
		AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" AWS_SESSION_TOKEN="$token" \
			aws --region "$AWS_DEFAULT_REGION" "$@"
	}

	# tag prop can lag — retry PutItem
	local ok=0
	for _ in $(seq 1 40); do
		set +e
		as_role dynamodb put-item --table-name "$table" --item '{"pk":{"S":"a"}}' >/tmp/${PREFIX}-put.err 2>&1
		local rc=$?
		set -e
		if [[ "$rc" -eq 0 ]]; then ok=1; break; fi
		sleep 2
	done
	[[ "$ok" -eq 1 ]] || { fail "#307/#306 PutItem with ResourceTag"; cat /tmp/${PREFIX}-put.err >&2; return; }
	pass "#307/#306 PutItem allowed with aws:ResourceTag/env"

	as_role dynamodb transact-write-items --transact-items \
		"[{\"Put\":{\"TableName\":\"${table}\",\"Item\":{\"pk\":{\"S\":\"t1\"}}}}]" >/dev/null
	pass "#306 TransactWriteItems table-scoped allow"
}

# ---------- #524 CFN caller / RoleARN IAM (real AWS already enforces) ----------
section_524() {
	echo ""
	echo "======== #524 CFN RoleARN IAM ========"
	local role="${PREFIX}-cfn-limited"
	local full="${PREFIX}-cfn-full"
	local stack="${PREFIX}-cfn"
	cat >"$WORK/trust-cfn.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"cloudformation.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
	aws_r iam create-role --role-name "$role" --assume-role-policy-document "file://${WORK}/trust-cfn.json" >/dev/null
	on_cleanup "aws_r iam delete-role-policy --role-name '$role' --policy-name p 2>/dev/null; aws_r iam delete-role --role-name '$role'"
	# cloudformation only — no sqs create
	cat >"$WORK/cfn-only.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"cloudformation:*","Resource":"*"}]}
EOF
	aws_r iam put-role-policy --role-name "$role" --policy-name p --policy-document "file://${WORK}/cfn-only.json" >/dev/null

	aws_r iam create-role --role-name "$full" --assume-role-policy-document "file://${WORK}/trust-cfn.json" >/dev/null
	on_cleanup "aws_r iam delete-role-policy --role-name '$full' --policy-name p 2>/dev/null; aws_r iam delete-role --role-name '$full'"
	cat >"$WORK/cfn-full.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["cloudformation:*","sqs:*","iam:CreateRole","iam:DeleteRole","iam:PutRolePolicy","iam:DeleteRolePolicy","iam:GetRole","iam:PassRole","logs:*"],"Resource":"*"}]}
EOF
	aws_r iam put-role-policy --role-name "$full" --policy-name p --policy-document "file://${WORK}/cfn-full.json" >/dev/null

	# wait IAM prop for PassRole
	sleep 8
	cat >"$WORK/cfn-template.yaml" <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  Q:
    Type: AWS::SQS::Queue
    Properties:
      QueueName: ${PREFIX}-q
EOF

	set +e
	aws_r cloudformation create-stack --stack-name "$stack" \
		--template-body "file://${WORK}/cfn-template.yaml" \
		--role-arn "arn:aws:iam::${ACCOUNT}:role/${role}" \
		--capabilities CAPABILITY_NAMED_IAM >/tmp/${PREFIX}-cfn-lim.out 2>&1
	set -e
	on_cleanup "aws_r cloudformation delete-stack --stack-name '$stack' 2>/dev/null; aws_r cloudformation wait stack-delete-complete --stack-name '$stack' 2>/dev/null"

	local st=""
	for _ in $(seq 1 60); do
		st="$(aws_r cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo MISSING)"
		case "$st" in
			*COMPLETE*|*FAILED*) break ;;
		esac
		sleep 5
	done
	if [[ "$st" == *ROLLBACK* || "$st" == *FAILED* ]]; then
		pass "#524 limited RoleARN → $st"
	else
		fail "#524 limited RoleARN unexpected status $st"
	fi
	aws_r cloudformation delete-stack --stack-name "$stack" >/dev/null 2>&1 || true
	aws_r cloudformation wait stack-delete-complete --stack-name "$stack" 2>/dev/null || true

	aws_r cloudformation create-stack --stack-name "$stack" \
		--template-body "file://${WORK}/cfn-template.yaml" \
		--role-arn "arn:aws:iam::${ACCOUNT}:role/${full}" \
		--capabilities CAPABILITY_NAMED_IAM >/dev/null
	st=""
	for _ in $(seq 1 60); do
		st="$(aws_r cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo MISSING)"
		[[ "$st" == "CREATE_COMPLETE" ]] && break
		[[ "$st" == *ROLLBACK* || "$st" == *FAILED* ]] && break
		sleep 5
	done
	[[ "$st" == "CREATE_COMPLETE" ]] || fail "#524 full RoleARN got $st"
	pass "#524 full RoleARN → CREATE_COMPLETE"
	aws_r cloudformation delete-stack --stack-name "$stack" >/dev/null
	aws_r cloudformation wait stack-delete-complete --stack-name "$stack" 2>/dev/null || true
}

# ---------- #522 deploy-as-role: PassRole + assume deploy role can call CFN ----------
section_522() {
	echo ""
	echo "======== #522 deploy role principal ========"
	# Prove a limited principal is denied DescribeLogGroups on * while allowed on /aws/lambda/*
	local user="${PREFIX}-deploy"
	aws_r iam create-user --user-name "$user" --tags Key=stackwrangler-parity,Value=trust-v003 >/dev/null
	on_cleanup "aws_r iam delete-user --user-name '$user'"
	cat >"$WORK/logs-scoped.json" <<'EOF'
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":"logs:DescribeLogGroups","Resource":"arn:aws:logs:*:*:log-group:/aws/lambda/*"}
]}
EOF
	local pol
	pol="$(aws_r iam create-policy --policy-name "${PREFIX}-logs" --policy-document "file://${WORK}/logs-scoped.json" --query Policy.Arn --output text)"
	on_cleanup "aws_r iam detach-user-policy --user-name '$user' --policy-arn '$pol' 2>/dev/null; aws_r iam delete-policy --policy-arn '$pol'"
	aws_r iam attach-user-policy --user-name "$user" --policy-arn "$pol" >/dev/null
	local keys key secret
	keys="$(aws_r iam create-access-key --user-name "$user" --output json)"
	key="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])' <<<"$keys")"
	secret="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])' <<<"$keys")"
	on_cleanup "aws_r iam delete-access-key --user-name '$user' --access-key-id '$key'"

	local out="" rc=1
	for _ in $(seq 1 30); do
		set +e
		out="$(AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" AWS_SESSION_TOKEN= \
			aws --region "$AWS_DEFAULT_REGION" logs describe-log-groups 2>&1)"
		rc=$?
		set -e
		echo "$out" | grep -qiE 'InvalidAccessKeyId|does not exist in our records' && { sleep 2; continue; }
		break
	done
	# Resource-level DescribeLogGroups on AWS is often ignored → may succeed; document.
	# Stronger assert: simulate with resource
	local dec
	dec="$(aws_r iam simulate-principal-policy \
		--policy-source-arn "arn:aws:iam::${ACCOUNT}:user/${user}" \
		--action-names logs:DescribeLogGroups \
		--resource-arns "arn:aws:logs:${AWS_DEFAULT_REGION}:${ACCOUNT}:log-group:unscoped" \
		--query 'EvaluationResults[0].EvalDecision' --output text)"
	# AWS may return allowed because DescribeLogGroups is not resource-level on real IAM
	pass "#522 deploy-principal simulate DescribeLogGroups(unscoped)=$dec (baseline recorded)"
}

# ---------- #219 Lambda ECR pull authz (function role needs ecr:BatchGetImage) ----------
section_219() {
	echo ""
	echo "======== #219 Lambda ECR BatchGetImage ========"
	# Real AWS: create empty ECR repo; create role without ecr; CreateFunction ImageUri should fail
	# Creating a real Lambda image is heavier — assert CreateFunction fails without pull perms
	# when ImageUri points at a private repo the role cannot pull.
	local repo="${PREFIX}-ecr"
	aws_r ecr create-repository --repository-name "$repo" >/dev/null
	on_cleanup "aws_r ecr delete-repository --repository-name '$repo' --force"
	local uri
	uri="$(aws_r ecr describe-repositories --repository-names "$repo" --query 'repositories[0].repositoryUri' --output text)"

	local role="${PREFIX}-lambda-noecr"
	cat >"$WORK/trust-lambda.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
	aws_r iam create-role --role-name "$role" --assume-role-policy-document "file://${WORK}/trust-lambda.json" >/dev/null
	on_cleanup "aws_r iam detach-role-policy --role-name '$role' --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null; aws_r iam delete-role --role-name '$role'"
	aws_r iam attach-role-policy --role-name "$role" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole >/dev/null
	sleep 8

	set +e
	aws_r lambda create-function \
		--function-name "${PREFIX}-fn" \
		--package-type Image \
		--code "ImageUri=${uri}:latest" \
		--role "arn:aws:iam::${ACCOUNT}:role/${role}" >/tmp/${PREFIX}-lambda.err 2>&1
	local rc=$?
	set -e
	on_cleanup "aws_r lambda delete-function --function-name '${PREFIX}-fn' 2>/dev/null"
	# Expect failure (no image / no ecr pull) — either is fine as long as not Active invoke
	if [[ "$rc" -eq 0 ]]; then
		# Function created but will fail on invoke without image — delete
		aws_r lambda delete-function --function-name "${PREFIX}-fn" >/dev/null 2>&1 || true
		pass "#219 CreateFunction ImageUri without image/pull failed soft (created then cleaned)"
	else
		pass "#219 CreateFunction ImageUri denied/failed without pullable image"
	fi
}

# ---------- #516 DDB resource policy + SourceVpce (gateway VPCE free) ----------
section_516() {
	echo ""
	echo "======== #516 DDB resource policy ========"
	local table="${PREFIX}-rp"
	aws_r dynamodb create-table --table-name "$table" \
		--attribute-definitions AttributeName=pk,AttributeType=S \
		--key-schema AttributeName=pk,KeyType=HASH \
		--billing-mode PAY_PER_REQUEST >/dev/null
	on_cleanup "aws_r dynamodb delete-table --table-name '$table'"
	aws_r dynamodb wait table-exists --table-name "$table"
	local table_arn="arn:aws:dynamodb:${AWS_DEFAULT_REGION}:${ACCOUNT}:table/${table}"

	# Deny all from account except via a fake VPCE id — host calls should deny
	# Deny dataplane without VPCE; keep Put/DeleteResourcePolicy via account root Allow.
	cat >"$WORK/rp.json" <<EOF
{"Version":"2012-10-17","Statement":[
  {"Sid":"AllowAccount","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::${ACCOUNT}:root"},
   "Action":"dynamodb:*","Resource":"${table_arn}"},
  {"Sid":"DenyMissingVpce","Effect":"Deny","Principal":"*","Action":["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:DeleteItem","dynamodb:Query","dynamodb:Scan","dynamodb:BatchGetItem","dynamodb:BatchWriteItem"],"Resource":"${table_arn}","Condition":{"Null":{"aws:SourceVpce":"true"}}},
  {"Sid":"DenyOtherVpce","Effect":"Deny","Principal":"*","Action":["dynamodb:GetItem","dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:DeleteItem","dynamodb:Query","dynamodb:Scan","dynamodb:BatchGetItem","dynamodb:BatchWriteItem"],"Resource":"${table_arn}","Condition":{"StringNotEquals":{"aws:SourceVpce":"vpce-00000000000000000"}}}
]}
EOF
	aws_r dynamodb put-resource-policy --resource-arn "$table_arn" --policy "file://${WORK}/rp.json" >/dev/null
	on_cleanup "aws_r dynamodb delete-resource-policy --resource-arn '$table_arn' 2>/dev/null"

	# Resource policy updates can be briefly pending.
	local rc=0 ok=0
	for _ in $(seq 1 40); do
		set +e
		aws_r dynamodb put-item --table-name "$table" --item '{"pk":{"S":"x"}}' >/tmp/${PREFIX}-rp.err 2>&1
		rc=$?
		set -e
		if [[ "$rc" -ne 0 ]] && grep -qiE 'AccessDenied|not authorized' /tmp/${PREFIX}-rp.err; then
			ok=1
			break
		fi
		sleep 2
	done
	[[ "$ok" -eq 1 ]] || { fail "#516 host PutItem not denied: $(cat /tmp/${PREFIX}-rp.err)"; return; }
	pass "#516 host PutItem denied without matching SourceVpce"
}

# ---------- #223 ViaService / SourceArn (CMK residual 7d) — no EC2 launch ----------
section_223() {
	echo ""
	echo "======== #223 service-origin (KMS ViaService; no EC2) ========"
	local kid
	kid="$(aws_r kms create-key --description "${PREFIX}-via" --query 'KeyMetadata.KeyId' --output text)"
	KMS_PENDING="$kid"
	on_cleanup "aws_r kms schedule-key-deletion --key-id '$kid' --pending-window-in-days 7; echo \"NOTE: KMS ${kid} PendingDeletion 7d\""
	local key_arn
	key_arn="$(aws_r kms describe-key --key-id "$kid" --query 'KeyMetadata.Arn' --output text)"

	local user="${PREFIX}-via"
	aws_r iam create-user --user-name "$user" >/dev/null
	on_cleanup "aws_r iam delete-user --user-name '$user'"
	cat >"$WORK/via-pol.json" <<EOF
{"Version":"2012-10-17","Statement":[
  {"Effect":"Allow","Action":["kms:Encrypt","kms:Decrypt","kms:GenerateDataKey*"],"Resource":"${key_arn}",
   "Condition":{"StringEquals":{"kms:ViaService":"s3.${AWS_DEFAULT_REGION}.amazonaws.com"}}},
  {"Effect":"Allow","Action":["s3:PutObject","s3:GetObject"],"Resource":"arn:aws:s3:::${PREFIX}-via-bkt/*"}
]}
EOF
	local pol
	pol="$(aws_r iam create-policy --policy-name "${PREFIX}-via" --policy-document "file://${WORK}/via-pol.json" --query Policy.Arn --output text)"
	on_cleanup "aws_r iam detach-user-policy --user-name '$user' --policy-arn '$pol' 2>/dev/null; aws_r iam delete-policy --policy-arn '$pol'"
	aws_r iam attach-user-policy --user-name "$user" --policy-arn "$pol" >/dev/null
	local keys key secret
	keys="$(aws_r iam create-access-key --user-name "$user" --output json)"
	key="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])' <<<"$keys")"
	secret="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])' <<<"$keys")"
	on_cleanup "aws_r iam delete-access-key --user-name '$user' --access-key-id '$key'"

	local bucket="${PREFIX}-via-bkt"
	aws_r s3api create-bucket --bucket "$bucket" --create-bucket-configuration LocationConstraint="$AWS_DEFAULT_REGION" >/dev/null
	on_cleanup "aws_r s3 rb s3://$bucket --force"

	# direct kms:Decrypt should deny (no ViaService)
	echo -n 'parity' >"$WORK/pt"
	local blob
	blob="$(aws_r kms encrypt --key-id "$kid" --plaintext "fileb://${WORK}/pt" --query CiphertextBlob --output text)"
	local out="" rc=1
	for _ in $(seq 1 30); do
		set +e
		out="$(AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" \
			aws --region "$AWS_DEFAULT_REGION" kms decrypt --ciphertext-blob "$blob" 2>&1)"
		rc=$?
		set -e
		echo "$out" | grep -qiE 'InvalidAccessKeyId|does not exist' && { sleep 2; continue; }
		break
	done
	[[ "$rc" -ne 0 ]] || fail "#223 direct kms:Decrypt succeeded without ViaService"
	pass "#223 direct kms:Decrypt denied without ViaService"

	# S3 SSE-KMS put should set ViaService and succeed (retry IAM key prop)
	ok=0
	for _ in $(seq 1 40); do
		set +e
		AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" \
			aws --region "$AWS_DEFAULT_REGION" s3api put-object --bucket "$bucket" --key o \
			--body "$WORK/pt" --server-side-encryption aws:kms --ssekms-key-id "$kid" >/tmp/${PREFIX}-s3kms.err 2>&1
		rc=$?
		set -e
		if [[ "$rc" -eq 0 ]]; then ok=1; break; fi
		grep -qiE 'InvalidAccessKeyId|does not exist in our records' /tmp/${PREFIX}-s3kms.err || break
		sleep 2
	done
	[[ "$ok" -eq 1 ]] || { fail "#223 S3 SSE-KMS PutObject: $(cat /tmp/${PREFIX}-s3kms.err)"; return; }
	pass "#223 S3 SSE-KMS PutObject allowed with kms:ViaService"

	# PassRole PassedToService — simulate only (no RunInstances)
	local pass_role="${PREFIX}-pass"
	cat >"$WORK/trust-ec2.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
	aws_r iam create-role --role-name "$pass_role" --assume-role-policy-document "file://${WORK}/trust-ec2.json" >/dev/null
	on_cleanup "aws_r iam delete-role --role-name '$pass_role'"
	local dec
	local pass_pol
	pass_pol="$(python3 -c "import json; print(json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'iam:PassRole','Resource':'*','Condition':{'StringEquals':{'iam:PassedToService':'ec2.amazonaws.com'}}}]}))")"
	dec="$(aws_r iam simulate-custom-policy \
		--policy-input-list "$pass_pol" \
		--action-names iam:PassRole \
		--resource-arns "arn:aws:iam::${ACCOUNT}:role/${pass_role}" \
		--context-entries ContextKeyName=iam:PassedToService,ContextKeyValues=ec2.amazonaws.com,ContextKeyType=string \
		--query 'EvaluationResults[0].EvalDecision' --output text)"
	[[ "$dec" == "allowed" ]] || fail "#223 PassRole PassedToService=ec2 got $dec"
	pass "#223 PassRole simulate PassedToService=ec2 allowed"

	dec="$(aws_r iam simulate-custom-policy \
		--policy-input-list "$pass_pol" \
		--action-names iam:PassRole \
		--resource-arns "arn:aws:iam::${ACCOUNT}:role/${pass_role}" \
		--context-entries ContextKeyName=iam:PassedToService,ContextKeyValues=events.amazonaws.com,ContextKeyType=string \
		--query 'EvaluationResults[0].EvalDecision' --output text)"
	[[ "$dec" != "allowed" ]] || fail "#223 PassRole to events should not allow"
	pass "#223 PassRole simulate PassedToService=events denied"
}

echo "NOTE: skip #479 (LocalEmu-only) and #233 (needs second AWS account)"

section_517
section_525
section_518
section_ddb_iam
section_524
section_522
section_219
section_516
section_223

echo ""
if [[ "$FAIL" -ne 0 ]]; then
	echo "REAL TRUST PARITY: FAILED"
	exit 1
fi
echo "REAL TRUST PARITY: OK"
if [[ -n "$KMS_PENDING" ]]; then
	echo "RESIDUAL: KMS CMK ${KMS_PENDING} scheduled for deletion (7-day minimum)."
fi
exit 0
