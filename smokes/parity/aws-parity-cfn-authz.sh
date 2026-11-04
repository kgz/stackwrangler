#!/usr/bin/env bash
# CFN sad parity: Lambda role without s3:PutObject → AccessDenied (LocalEmu + real AWS).
# Short-lived; always tear down. Usage: ./bin/aws-parity-cfn-authz.sh
# Env: AWSBOX_PARITY_SKIP_LOCAL=1 | AWSBOX_PARITY_SKIP_REAL=1 | AWSBOX_PARITY_KEEP=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/cloudformation/s3-lambda-deny"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

TS="$(date +%s)"
KEEP="${AWSBOX_PARITY_KEEP:-0}"
LOCAL_EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
LOCAL_KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
LOCAL_SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
LOCAL_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
REAL_REGION="${AWSBOX_PARITY_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-2}}"

mkdir -p "$EX/build"
(
	cd "$EX/src"
	zip -q -FS "$EX/build/function.zip" index.js
)

teardown_side() {
	local label="$1" stack="$2" bucket="$3" code_bucket="$4" fn="$5"
	[[ "$KEEP" == "1" ]] && {
		echo "KEEP=1 — left ${label} stack=${stack}"
		return 0
	}
	echo "==> ${label}: teardown"
	aws_cli s3 rb "s3://${bucket}" --force >/dev/null 2>&1 || true
	aws_cli s3 rb "s3://${code_bucket}" --force >/dev/null 2>&1 || true
	aws_cli cloudformation delete-stack --stack-name "$stack" >/dev/null 2>&1 || true
	set +e
	aws_cli cloudformation wait stack-delete-complete --stack-name "$stack" 2>/dev/null
	set -e
	aws_cli lambda delete-function --function-name "$fn" >/dev/null 2>&1 || true
}

run_side() {
	local label="$1"
	local bucket="awsbox-cfnad-${label}-${TS}"
	local fn="awsbox-cfnad-${label}-${TS}"
	local code_bucket="awsbox-cfnad-${label}-code-${TS}"
	local stack="awsbox-cfnad-${label}-${TS}"
	local out="/tmp/awsbox-cfn-authz-${label}-${TS}.json"

	echo "==> ${label}: create code bucket + upload zip"
	aws_cli s3 mb "s3://${code_bucket}"
	aws_cli s3 cp "$EX/build/function.zip" "s3://${code_bucket}/function.zip"

	echo "==> ${label}: cloudformation deploy ${stack} (logs-only role)"
	aws_cli cloudformation deploy \
		--stack-name "$stack" \
		--template-file "$EX/template.yaml" \
		--capabilities CAPABILITY_NAMED_IAM \
		--parameter-overrides \
		"BucketName=${bucket}" \
		"FunctionName=${fn}" \
		"CodeBucket=${code_bucket}" \
		"CodeKey=function.zip"

	echo "==> ${label}: wait Lambda Active"
	local st=""
	for _ in $(seq 1 90); do
		st="$(aws_cli lambda get-function --function-name "$fn" \
			--query 'Configuration.State' --output text 2>/dev/null || echo Pending)"
		[[ "$st" == "Active" ]] && break
		sleep 2
	done
	[[ "$st" == "Active" ]] || {
		echo "FAIL (${label}): function never Active (state=${st})" >&2
		teardown_side "$label" "$stack" "$bucket" "$code_bucket" "$fn"
		return 1
	}

	echo "==> ${label}: invoke (expect AccessDenied in payload)"
	local body=""
	local saw_deny=0
	for _ in $(seq 1 30); do
		set +e
		aws_cli lambda invoke \
			--function-name "$fn" \
			--payload '{"source":"aws-parity-cfn-authz"}' \
			--cli-binary-format raw-in-base64-out \
			"$out" >/tmp/awsbox-cfn-authz-inv-${label}.txt 2>&1
		local irc=$?
		set -e
		[[ "$irc" -eq 0 && -f "$out" ]] || {
			sleep 3
			continue
		}
		body="$(cat "$out")"
		# Must not have written
		if echo "$body" | grep -qE '"wrote"[[:space:]]*:[[:space:]]*true'; then
			echo "FAIL (${label}): put succeeded; expected AccessDenied" >&2
			echo "$body" >&2
			teardown_side "$label" "$stack" "$bucket" "$code_bucket" "$fn"
			return 1
		fi
		if echo "$body" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|Unauthorized|Forbidden|Access Denied'; then
			saw_deny=1
			break
		fi
		# IAM prop may still be settling — empty message retries
		sleep 3
	done

	if [[ "$saw_deny" -ne 1 ]]; then
		echo "FAIL (${label}): expected AccessDenied-class error in payload:" >&2
		echo "${body:-"(empty)"}" >&2
		cat /tmp/awsbox-cfn-authz-inv-${label}.txt 2>/dev/null || true
		teardown_side "$label" "$stack" "$bucket" "$code_bucket" "$fn"
		return 1
	fi

	# Object must not exist
	set +e
	aws_cli s3api head-object --bucket "$bucket" --key authz-probe.txt >/dev/null 2>&1
	local head_rc=$?
	set -e
	if [[ "$head_rc" -eq 0 ]]; then
		echo "FAIL (${label}): authz-probe.txt exists despite deny" >&2
		teardown_side "$label" "$stack" "$bucket" "$code_bucket" "$fn"
		return 1
	fi

	echo "OK (${label}): CFN empty role → AccessDenied"
	echo "$body" | head -c 400
	echo
	teardown_side "$label" "$stack" "$bucket" "$code_bucket" "$fn"
}

if [[ "${AWSBOX_PARITY_SKIP_LOCAL:-0}" != "1" ]]; then
	echo "======== LOCAL ========"
	# shellcheck disable=SC1091
	source "$ROOT/smokes/lib/local-emu-env.sh"
	export AWS_ACCESS_KEY_ID="$LOCAL_KEY"
	export AWS_SECRET_ACCESS_KEY="$LOCAL_SECRET"
	export AWS_DEFAULT_REGION="$LOCAL_REGION"
	aws_cli() {
		command aws --endpoint-url "$LOCAL_EP" --region "$LOCAL_REGION" "$@"
	}
	run_side "local"
fi

if [[ "${AWSBOX_PARITY_SKIP_REAL:-0}" != "1" ]]; then
	export AWSBOX_ALLOW_REAL_AWS=1
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
	unset AWS_PROFILE AWS_DEFAULT_PROFILE
	export AWS_DEFAULT_REGION="$REAL_REGION"
	aws_cli() {
		command aws --region "$REAL_REGION" "$@"
	}
	echo "==> real caller"
	aws_cli sts get-caller-identity
	run_side "real"
fi

echo "OK: CFN authz parity complete (ts=${TS})"
