#!/usr/bin/env bash
# CFN S3+Lambda parity: LocalEmu then real AWS (default creds). Short-lived; always tear down.
# Cost: free-tier / noise if delete succeeds. Usage: ./smokes/parity/aws-parity-cfn-s3-lambda.sh
# Env: AWSBOX_PARITY_SKIP_LOCAL=1 | AWSBOX_PARITY_SKIP_REAL=1 | AWSBOX_PARITY_KEEP=1
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/cloudformation/s3-lambda"
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

run_side() {
	local label="$1"
	local region="$2"
	# remaining args: aws wrapper is via AWS_CMD array set by caller — we use functions
	local bucket="awsbox-cfnp-${label}-${TS}"
	local fn="awsbox-cfnp-${label}-${TS}"
	local code_bucket="awsbox-cfnp-${label}-code-${TS}"
	local stack="awsbox-cfnp-${label}-${TS}"
	local out="/tmp/awsbox-cfn-parity-${label}-${TS}.json"

	echo "==> ${label}: create code bucket + upload zip"
	aws_cli s3 mb "s3://${code_bucket}"
	aws_cli s3 cp "$EX/build/function.zip" "s3://${code_bucket}/function.zip"

	echo "==> ${label}: cloudformation deploy ${stack}"
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

	echo "==> ${label}: invoke (retry for IAM prop)"
	local inv_ok=0
	for _ in $(seq 1 30); do
		set +e
		aws_cli lambda invoke \
			--function-name "$fn" \
			--payload '{"source":"aws-parity-cfn"}' \
			--cli-binary-format raw-in-base64-out \
			"$out" >/tmp/awsbox-cfn-parity-inv-${label}.txt 2>&1
		local irc=$?
		set -e
		if [[ "$irc" -eq 0 ]] && grep -qE '"ok"[[:space:]]*:[[:space:]]*true' "$out" 2>/dev/null; then
			inv_ok=1
			break
		fi
		# role prop / ResourceConflict
		sleep 3
	done
	if [[ "$inv_ok" -ne 1 ]]; then
		echo "FAIL (${label}): invoke did not return ok:true" >&2
		cat "$out" 2>/dev/null || true
		cat /tmp/awsbox-cfn-parity-inv-${label}.txt 2>/dev/null || true
		teardown_side "$label" "$stack" "$bucket" "$code_bucket" "$fn"
		return 1
	fi
	echo "Payload=$(cat "$out")"

	echo "==> ${label}: assert S3 write"
	local list=""
	list="$(aws_cli s3 ls "s3://${bucket}/writes/" || true)"
	echo "$list"
	if ! echo "$list" | grep -q .; then
		echo "FAIL (${label}): no objects under s3://${bucket}/writes/" >&2
		teardown_side "$label" "$stack" "$bucket" "$code_bucket" "$fn"
		return 1
	fi

	echo "OK (${label}): CFN S3+Lambda (${stack})"
	teardown_side "$label" "$stack" "$bucket" "$code_bucket" "$fn"
}

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
	# Best-effort wait (role/bucket may already be gone)
	set +e
	aws_cli cloudformation wait stack-delete-complete --stack-name "$stack" 2>/dev/null
	set -e
	aws_cli lambda delete-function --function-name "$fn" >/dev/null 2>&1 || true
}

# --- LocalEmu ---
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
	run_side "local" "$LOCAL_REGION"
fi

# --- Real AWS (default shared credentials; strip local overrides) ---
if [[ "${AWSBOX_PARITY_SKIP_REAL:-0}" != "1" ]]; then
	export AWSBOX_ALLOW_REAL_AWS=1
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
	unset AWS_PROFILE AWS_DEFAULT_PROFILE
	unset AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
	unset AWS_EC2_METADATA_DISABLED
	export AWS_DEFAULT_REGION="$REAL_REGION"
	aws_cli() {
		command aws --region "$REAL_REGION" "$@"
	}
	echo "==> real caller"
	aws_cli sts get-caller-identity
	run_side "real" "$REAL_REGION"
fi

echo "OK: CFN S3+Lambda parity complete (ts=${TS})"
