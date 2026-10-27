#!/usr/bin/env bash
# #83: Elastic Beanstalk stub — create/describe application (no environment dataplane).
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
APP="awsbox-eb-${TS}"
KEEP="${AWSBOX_EB_KEEP:-0}"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws elasticbeanstalk delete-application --application-name "$APP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

aws elasticbeanstalk create-application --application-name "$APP" \
	--description "awsbox stub ${TS}" >/dev/null

FOUND="$(
	aws elasticbeanstalk describe-applications --application-names "$APP" \
		--query 'Applications[0].ApplicationName' --output text
)"
[[ "$FOUND" == "$APP" ]] || {
	echo "FAIL: describe-applications got ${FOUND}" >&2
	exit 1
}

STACKS="$(aws elasticbeanstalk list-available-solution-stacks --query 'length(SolutionStacks)' --output text)"
[[ "$STACKS" != "0" && "$STACKS" != "None" ]] || {
	echo "FAIL: no solution stacks" >&2
	exit 1
}

echo "OK: elasticbeanstalk create/describe application (${APP} stacks=${STACKS})"
