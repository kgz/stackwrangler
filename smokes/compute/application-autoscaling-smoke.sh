#!/usr/bin/env bash
# #83: Application Auto Scaling stub — register/describe scalable target.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

TS="$(date +%s)"
TABLE="awsbox-aas-${TS}"
RID="table/${TABLE}"
KEEP="${AWSBOX_AAS_KEEP:-0}"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws application-autoscaling deregister-scalable-target \
		--service-namespace dynamodb --resource-id "$RID" \
		--scalable-dimension dynamodb:table:ReadCapacityUnits \
		>/dev/null 2>&1 || true
}
trap cleanup EXIT

aws application-autoscaling register-scalable-target \
	--service-namespace dynamodb \
	--resource-id "$RID" \
	--scalable-dimension dynamodb:table:ReadCapacityUnits \
	--min-capacity 1 --max-capacity 10 >/dev/null

FOUND="$(
	aws application-autoscaling describe-scalable-targets \
		--service-namespace dynamodb --resource-ids "$RID" \
		--query 'ScalableTargets[0].ResourceId' --output text
)"
[[ "$FOUND" == "$RID" ]] || {
	echo "FAIL: describe-scalable-targets got ${FOUND}" >&2
	exit 1
}

echo "OK: application-autoscaling register/describe (${RID})"
