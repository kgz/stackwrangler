#!/usr/bin/env bash
# Sad path: Transfer user role with no S3 perms → PutObject AccessDenied.
# Sidecar dataplane uses admin keys; this asserts the workload principal shape.
# Happy: ./smokes/transfer/transfer-smoke.sh
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
BUCKET="awsbox-xfer-authz-${TS}"
ROLE="awsbox-xfer-noperm-${TS}"
USER="xfer-deny"
KEEP="${AWSBOX_TRANSFER_KEEP:-0}"
SID=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	if [[ -n "$SID" ]]; then
		aws transfer delete-user --server-id "$SID" --user-name "$USER" >/dev/null 2>&1 || true
		aws transfer delete-server --server-id "$SID" >/dev/null 2>&1 || true
	fi
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"transfer.amazonaws.com"},"Action":"sts:AssumeRole"}]}'

aws s3 mb "s3://${BUCKET}" >/dev/null

# Role Transfer can assume — no S3 permissions.
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

SID="$(aws transfer create-server \
	--protocols SFTP \
	--identity-provider-type SERVICE_MANAGED \
	--query 'ServerId' --output text)"

aws transfer create-user \
	--server-id "$SID" \
	--user-name "$USER" \
	--role "$ROLE_ARN" \
	--home-directory "/${BUCKET}" \
	--home-directory-type PATH >/dev/null

DESC="$(aws transfer describe-user --server-id "$SID" --user-name "$USER" --output json)"
echo "$DESC" | python3 -c '
import json,sys
u=json.load(sys.stdin)["User"]
assert "'"$ROLE"'" in u["Role"], u.get("Role")
print("user role ok:", u["Role"])
'

# Trust is transfer.amazonaws.com only — CLI cannot AssumeRole. Simulate like real-AWS empty-role probe.
set +e
SIM="$(
	aws iam simulate-principal-policy \
		--policy-source-arn "$ROLE_ARN" \
		--action-names s3:PutObject \
		--resource-arns "arn:aws:s3:::${BUCKET}/authz-probe.txt" \
		--output json 2>&1
)"
SIM_RC=$?
set -e
if [[ "$SIM_RC" -ne 0 ]]; then
	echo "FAIL: simulate-principal-policy:" >&2
	echo "$SIM" >&2
	exit 1
fi

DECISION="$(echo "$SIM" | python3 -c '
import json,sys
print(json.load(sys.stdin)["EvaluationResults"][0]["EvalDecision"])
')"
if [[ "$DECISION" != "implicitDeny" && "$DECISION" != "explicitDeny" && "$DECISION" != "denied" ]]; then
	echo "FAIL: expected deny for empty Transfer role, got: $DECISION" >&2
	echo "$SIM" >&2
	exit 1
fi

echo "OK: Transfer role without s3:PutObject → ${DECISION} (server=${SID})"

