#!/usr/bin/env bash
# Real-AWS parity for messaging/data/crypto batch + logs/apigw/ec2 authz.
# Local: existing *-smoke.sh / *-authz-smoke.sh. Real: short-lived create→assert→delete.
# Cost: free-tier/noise if teardown OK. KMS: CMK + 7-day pending delete (small prorate).
# No successful EC2 RunInstances on real (deny-only).
# Usage: ./smokes/parity/aws-parity-batch10.sh
# Env: AWSBOX_PARITY_SKIP_LOCAL=1 | AWSBOX_PARITY_SKIP_REAL=1 | AWSBOX_PARITY_KEEP=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

TS="$(date +%s)"
KEEP="${AWSBOX_PARITY_KEEP:-0}"
# Prefer explicit parity region; do not inherit local us-east-1 from .env after local smokes.
REAL_REGION="${AWSBOX_PARITY_REGION:-ap-southeast-2}"
FAIL=0
CLEANUP_CMDS=()

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

# Register LIFO cleanup (runs on EXIT unless KEEP=1). Commands must be idempotent.
on_cleanup() {
	CLEANUP_CMDS+=("$*")
}

run_cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	local i
	for ((i = ${#CLEANUP_CMDS[@]} - 1; i >= 0; i--)); do
		# shellcheck disable=SC2086
		eval "${CLEANUP_CMDS[i]}" >/dev/null 2>&1 || true
	done
}

# Temp IAM keys are eventually consistent on real AWS.
# Always returns 0 so set -e cannot skip registered cleanup.
deny_until() {
	local label="$1"
	shift
	local out="" rc=1 i
	for i in $(seq 1 45); do
		set +e
		out="$("$@" 2>&1)"
		rc=$?
		set -e
		if echo "$out" | grep -qiE 'InvalidClientTokenId|UnrecognizedClientException|AuthFailure|does not exist in our records|InvalidAccessKeyId'; then
			sleep 2
			continue
		fi
		if [[ "$rc" -ne 0 ]] && echo "$out" | grep -qiE 'AccessDenied|UnauthorizedOperation|not authorized|ExplicitDeny|Forbidden'; then
			pass "$label"
			return 0
		fi
		break
	done
	fail "$label: $out"
	return 0
}

mk_deny_user() {
	# mk_deny_user <user> <policy-name> <policy-json-doc>
	# Sets globals: USER POL PARN AK SK
	USER="$1"
	POL="$2"
	local doc="$3"
	aws_r iam create-user --user-name "$USER" >/dev/null
	on_cleanup "aws_r iam delete-user --user-name '$USER'"
	PARN="$(aws_r iam create-policy --policy-name "$POL" --policy-document "$doc" --query Policy.Arn --output text)"
	on_cleanup "aws_r iam delete-policy --policy-arn '$PARN'"
	aws_r iam attach-user-policy --user-name "$USER" --policy-arn "$PARN" >/dev/null
	on_cleanup "aws_r iam detach-user-policy --user-name '$USER' --policy-arn '$PARN'"
	local KJ
	KJ="$(aws_r iam create-access-key --user-name "$USER" --output json)"
	AK="$(echo "$KJ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
	SK="$(echo "$KJ" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"
	on_cleanup "aws_r iam delete-access-key --user-name '$USER' --access-key-id '$AK'"
}

# --- Local (existing smokes) ---
if [[ "${AWSBOX_PARITY_SKIP_LOCAL:-0}" != "1" ]]; then
	echo "======== LOCAL ========"
	# shellcheck disable=SC1091
	source "$ROOT/smokes/lib/local-emu-env.sh"
	source "$ROOT/smokes/lib/smoke-path.sh"
	for s in \
		sns-smoke sns-authz-smoke \
		events-smoke events-authz-smoke \
		dynamodb-smoke dynamodb-authz-smoke \
		sfn-smoke sfn-authz-smoke \
		secrets-smoke secrets-authz-smoke \
		kms-smoke kms-authz-smoke \
		kinesis-smoke kinesis-authz-smoke \
		logs-authz-smoke apigw-authz-smoke ec2-authz-smoke
	do
		echo "---- local ${s} ----"
		if ! "$(smoke_path "$s")"; then
			fail "local ${s}"
		fi
	done
fi

# --- Real AWS ---
if [[ "${AWSBOX_PARITY_SKIP_REAL:-0}" != "1" ]]; then
	echo "======== REAL (${REAL_REGION}) ========"
	export AWSBOX_ALLOW_REAL_AWS=1
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
	unset AWS_PROFILE AWS_DEFAULT_PROFILE
	unset AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
	unset AWS_EC2_METADATA_DISABLED
	export AWS_DEFAULT_REGION="$REAL_REGION"
	aws_r() { command aws --region "$REAL_REGION" "$@"; }
	trap run_cleanup EXIT
	aws_r sts get-caller-identity

	# SNS happy + authz
	echo "---- real sns ----"
	TOPIC="awsbox-parity-sns-${TS}"
	TOPIC_ARN="$(aws_r sns create-topic --name "$TOPIC" --query TopicArn --output text)"
	on_cleanup "aws_r sns delete-topic --topic-arn '$TOPIC_ARN'"
	MID="$(aws_r sns publish --topic-arn "$TOPIC_ARN" --message "parity-${TS}" --query MessageId --output text)"
	[[ -n "$MID" && "$MID" != "None" ]] && pass "real sns publish" || fail "real sns publish"
	mk_deny_user "awsbox-parity-sns-deny-${TS}" "awsbox-parity-deny-sns-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"sns:Publish","Resource":"*"}]}'
	deny_until "real sns deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" sns publish --topic-arn "$TOPIC_ARN" --message x

	# EventBridge
	echo "---- real events ----"
	RULE="awsbox-parity-eb-${TS}"
	ENTRIES="$(python3 -c "import json; print(json.dumps([{'Source':'awsbox.parity','DetailType':'ping','Detail':json.dumps({'ts':$TS})}]))")"
	FC="$(aws_r events put-events --entries "$ENTRIES" --query FailedEntryCount --output text)"
	[[ "$FC" == "0" ]] && pass "real put-events" || fail "real put-events failed=$FC"
	aws_r events put-rule --name "$RULE" --event-pattern '{"source":["awsbox.parity"]}' --state ENABLED >/dev/null
	on_cleanup "aws_r events delete-rule --name '$RULE'"
	aws_r events describe-rule --name "$RULE" --query Name --output text | grep -qx "$RULE" && pass "real events rule" || fail "real events rule"
	mk_deny_user "awsbox-parity-eb-deny-${TS}" "awsbox-parity-deny-eb-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"events:PutEvents","Resource":"*"}]}'
	deny_until "real events deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" events put-events --entries '[{"Source":"x","DetailType":"y","Detail":"{}"}]'

	# DynamoDB
	echo "---- real dynamodb ----"
	TABLE="awsbox-parity-ddb-${TS}"
	aws_r dynamodb create-table --table-name "$TABLE" \
		--attribute-definitions AttributeName=pk,AttributeType=S \
		--key-schema AttributeName=pk,KeyType=HASH \
		--billing-mode PAY_PER_REQUEST >/dev/null
	on_cleanup "aws_r dynamodb delete-table --table-name '$TABLE'"
	for _ in $(seq 1 60); do
		st="$(aws_r dynamodb describe-table --table-name "$TABLE" --query Table.TableStatus --output text 2>/dev/null || true)"
		[[ "$st" == "ACTIVE" ]] && break
		sleep 2
	done
	aws_r dynamodb put-item --table-name "$TABLE" --item '{"pk":{"S":"one"},"note":{"S":"parity"}}' >/dev/null
	NOTE="$(aws_r dynamodb get-item --table-name "$TABLE" --key '{"pk":{"S":"one"}}' --query 'Item.note.S' --output text)"
	[[ "$NOTE" == "parity" ]] && pass "real ddb put/get" || fail "real ddb put/get"
	mk_deny_user "awsbox-parity-ddb-deny-${TS}" "awsbox-parity-deny-ddb-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"dynamodb:PutItem","Resource":"*"}]}'
	deny_until "real ddb deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" dynamodb put-item --table-name "$TABLE" --item '{"pk":{"S":"x"}}'

	# Step Functions
	echo "---- real sfn ----"
	NAME="awsbox-parity-sfn-${TS}"
	ROLE="awsbox-parity-sfn-role-${TS}"
	TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"states.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
	aws_r iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
	on_cleanup "aws_r iam delete-role --role-name '$ROLE'"
	ROLE_ARN="$(aws_r iam get-role --role-name "$ROLE" --query Role.Arn --output text)"
	sleep 8
	DEF='{"StartAt":"Hi","States":{"Hi":{"Type":"Pass","Result":{"ok":true},"End":true}}}'
	SM_ARN="$(aws_r stepfunctions create-state-machine --name "$NAME" --definition "$DEF" --role-arn "$ROLE_ARN" --query stateMachineArn --output text)"
	# delete-state-machine is async; wait so the IAM role delete that follows does not race.
	on_cleanup "aws_r stepfunctions delete-state-machine --state-machine-arn '$SM_ARN'; for _ in \$(seq 1 30); do aws_r stepfunctions describe-state-machine --state-machine-arn '$SM_ARN' >/dev/null 2>&1 || break; sleep 1; done"
	EXEC="$(aws_r stepfunctions start-execution --state-machine-arn "$SM_ARN" --name "run-${TS}" --query executionArn --output text)"
	st=""
	for _ in $(seq 1 30); do
		st="$(aws_r stepfunctions describe-execution --execution-arn "$EXEC" --query status --output text)"
		[[ "$st" == "SUCCEEDED" ]] && break
		[[ "$st" == "FAILED" || "$st" == "TIMED_OUT" || "$st" == "ABORTED" ]] && break
		sleep 1
	done
	[[ "$st" == "SUCCEEDED" ]] && pass "real sfn Pass" || fail "real sfn status=$st"
	mk_deny_user "awsbox-parity-sfn-deny-${TS}" "awsbox-parity-deny-sfn-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"states:StartExecution","Resource":"*"}]}'
	deny_until "real sfn deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" stepfunctions start-execution --state-machine-arn "$SM_ARN" --name "deny-${TS}"

	# Secrets
	echo "---- real secrets ----"
	SNAME="awsbox/parity-secret-${TS}"
	SARN="$(aws_r secretsmanager create-secret --name "$SNAME" --secret-string "parity-${TS}" --query ARN --output text)"
	on_cleanup "aws_r secretsmanager delete-secret --secret-id '$SARN' --force-delete-without-recovery"
	VAL="$(aws_r secretsmanager get-secret-value --secret-id "$SARN" --query SecretString --output text)"
	[[ "$VAL" == "parity-${TS}" ]] && pass "real secrets get" || fail "real secrets get"
	mk_deny_user "awsbox-parity-sec-deny-${TS}" "awsbox-parity-deny-sec-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"secretsmanager:GetSecretValue","Resource":"*"}]}'
	deny_until "real secrets deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" secretsmanager get-secret-value --secret-id "$SARN"

	# KMS — reuse fixture when present (alias/sw-parity-fixture-batch10)
	echo "---- real kms ----"
	PT="${TMPDIR:-/tmp}/awsbox-parity-kms-pt-$$"
	printf 'awsbox' >"$PT"
	KID="${AWSBOX_PARITY_KMS_BATCH_KEY_ID:-alias/sw-parity-fixture-batch10}"
	if aws_r kms describe-key --key-id "$KID" --query 'KeyMetadata.KeyId' --output text >/tmp/awsbox-parity-kms.id 2>/tmp/awsbox-parity-kms.err; then
		KID="$(cat /tmp/awsbox-parity-kms.id)"
		echo "NOTE: reusing fixture CMK ${KID} (no create / no schedule-deletion)"
	else
		KID="$(aws_r kms create-key --description "awsbox-parity-kms-${TS}" --query KeyMetadata.KeyId --output text)"
		# AWS minimum pending window is 7 days — only residual cost after run.
		on_cleanup "aws_r kms schedule-key-deletion --key-id '$KID' --pending-window-in-days 7"
		echo "NOTE: KMS key ${KID} will be scheduled for deletion on exit (7d min window)"
	fi
	BLOB="$(aws_r kms encrypt --key-id "$KID" --plaintext "fileb://${PT}" --query CiphertextBlob --output text)"
	RAW="$(aws_r kms decrypt --ciphertext-blob "$BLOB" --query Plaintext --output text)"
	DEC="$(echo "$RAW" | base64 -d)"
	rm -f "$PT"
	[[ "$DEC" == "awsbox" ]] && pass "real kms encrypt/decrypt" || fail "real kms encrypt/decrypt"
	mk_deny_user "awsbox-parity-kms-deny-${TS}" "awsbox-parity-deny-kms-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"kms:Decrypt","Resource":"*"}]}'
	deny_until "real kms deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" kms decrypt --ciphertext-blob "$BLOB"

	# Kinesis
	echo "---- real kinesis ----"
	STREAM="awsbox-parity-kin-${TS}"
	aws_r kinesis create-stream --stream-name "$STREAM" --shard-count 1 >/dev/null
	on_cleanup "aws_r kinesis delete-stream --stream-name '$STREAM'"
	for _ in $(seq 1 90); do
		st="$(aws_r kinesis describe-stream-summary --stream-name "$STREAM" --query StreamDescriptionSummary.StreamStatus --output text 2>/dev/null || true)"
		[[ "$st" == "ACTIVE" ]] && break
		sleep 2
	done
	DF="${TMPDIR:-/tmp}/awsbox-parity-kin-$$"
	printf 'parity-%s' "$TS" >"$DF"
	SEQ="$(aws_r kinesis put-record --stream-name "$STREAM" --partition-key pk --data "fileb://${DF}" --query SequenceNumber --output text)"
	rm -f "$DF"
	[[ -n "$SEQ" && "$SEQ" != "None" ]] && pass "real kinesis put" || fail "real kinesis put"
	mk_deny_user "awsbox-parity-kin-deny-${TS}" "awsbox-parity-deny-kin-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"kinesis:PutRecord","Resource":"*"}]}'
	KF="${TMPDIR:-/tmp}/awsbox-parity-kin-deny-$$"; printf x >"$KF"
	deny_until "real kinesis deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" kinesis put-record --stream-name "$STREAM" --partition-key pk --data "fileb://${KF}"
	rm -f "$KF"

	# Logs authz only
	echo "---- real logs authz ----"
	GROUP="/awsbox/parity-logs-${TS}"
	aws_r logs create-log-group --log-group-name "$GROUP" >/dev/null
	on_cleanup "aws_r logs delete-log-group --log-group-name '$GROUP'"
	aws_r logs create-log-stream --log-group-name "$GROUP" --log-stream-name s1 >/dev/null
	mk_deny_user "awsbox-parity-logs-deny-${TS}" "awsbox-parity-deny-logs-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"logs:PutLogEvents","Resource":"*"}]}'
	NOW=$(($(date +%s) * 1000))
	deny_until "real logs deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" logs put-log-events --log-group-name "$GROUP" --log-stream-name s1 --log-events "timestamp=${NOW},message=x"

	# API GW authz
	echo "---- real apigw authz ----"
	mk_deny_user "awsbox-parity-apigw-deny-${TS}" "awsbox-parity-deny-apigw-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":["apigateway:POST","apigateway:GET"],"Resource":"*"}]}'
	deny_until "real apigw deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" apigatewayv2 create-api --name "deny-${TS}" --protocol-type HTTP

	# EC2 authz only (no instance create)
	echo "---- real ec2 authz ----"
	mk_deny_user "awsbox-parity-ec2-deny-${TS}" "awsbox-parity-deny-ec2-${TS}" \
		'{"Version":"2012-10-17","Statement":[{"Effect":"Deny","Action":"ec2:RunInstances","Resource":"*"}]}'
	sleep 2
	AMI="$(aws_r ec2 describe-images --owners amazon \
		--filters Name=name,Values='al2023-ami-*-x86_64' Name=state,Values=available \
		--query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text 2>/dev/null || echo ami-invalid)"
	deny_until "real ec2 deny" env AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK" aws --region "$REAL_REGION" ec2 run-instances --image-id "$AMI" --instance-type t3.micro --count 1
fi

if [[ "$FAIL" -ne 0 ]]; then
	echo "FAIL: aws-parity-batch10 had failures (ts=${TS})" >&2
	exit 1
fi
echo "OK: aws-parity-batch10 complete (ts=${TS})"
