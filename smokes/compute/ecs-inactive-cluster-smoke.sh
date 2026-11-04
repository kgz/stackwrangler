#!/usr/bin/env bash
# After delete-cluster, list-clusters must omit the INACTIVE ARN; describe may still return it (#401).
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
CLUSTER="awsbox-ecs-inactive-${TS}"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null
ARN="$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].clusterArn' --output text)"
[[ -n "$ARN" && "$ARN" != "None" ]] || {
	echo "FAIL: create-cluster did not yield an ARN" >&2
	exit 1
}

listed="$(aws ecs list-clusters --query 'clusterArns' --output text)"
echo "$listed" | grep -q "$ARN" || {
	echo "FAIL: active cluster missing from list-clusters: $ARN" >&2
	echo "list: $listed" >&2
	exit 1
}

status="$(aws ecs delete-cluster --cluster "$CLUSTER" --query 'cluster.status' --output text)"
[[ "$status" == "INACTIVE" ]] || {
	echo "FAIL: delete-cluster status want INACTIVE got $status" >&2
	exit 1
}

listed_after="$(aws ecs list-clusters --query 'clusterArns' --output text || true)"
if echo "$listed_after" | grep -q "$ARN"; then
	echo "FAIL: INACTIVE cluster still in list-clusters: $ARN" >&2
	echo "list: $listed_after" >&2
	exit 1
fi

desc_status="$(aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text)"
[[ "$desc_status" == "INACTIVE" ]] || {
	echo "FAIL: describe after delete want INACTIVE got $desc_status" >&2
	exit 1
}

echo "OK: list-clusters omits INACTIVE $CLUSTER; describe still returns INACTIVE"
