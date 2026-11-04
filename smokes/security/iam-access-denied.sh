#!/usr/bin/env bash
# Assert AccessDenied: deny-policy user cannot ListBuckets on LocalStack S3.
# Usage: ./bin/iam-access-denied.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

IAM_EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
ADMIN_KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
ADMIN_SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
USER="awsbox-denied-$(date +%s)"
POLICY_NAME="AwsboxDenyS3List"
TMPDIR="${TMPDIR:-/tmp}"
POLICY_DOC="${TMPDIR}/awsbox-deny-s3-$$.json"

cleanup() {
	rm -f "$POLICY_DOC"
	AWS_ACCESS_KEY_ID="$ADMIN_KEY" AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET" \
		aws --endpoint-url "$IAM_EP" --region "$REGION" \
		iam delete-access-key --user-name "$USER" --access-key-id "${DENIED_KEY:-}" 2>/dev/null || true
	AWS_ACCESS_KEY_ID="$ADMIN_KEY" AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET" \
		aws --endpoint-url "$IAM_EP" --region "$REGION" \
		iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" 2>/dev/null || true
	AWS_ACCESS_KEY_ID="$ADMIN_KEY" AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET" \
		aws --endpoint-url "$IAM_EP" --region "$REGION" \
		iam delete-user --user-name "$USER" 2>/dev/null || true
	AWS_ACCESS_KEY_ID="$ADMIN_KEY" AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET" \
		aws --endpoint-url "$IAM_EP" --region "$REGION" \
		iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
}
trap cleanup EXIT

cat >"$POLICY_DOC" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyListBuckets",
      "Effect": "Deny",
      "Action": "s3:ListAllMyBuckets",
      "Resource": "*"
    }
  ]
}
EOF

export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"

aws --endpoint-url "$IAM_EP" --region "$REGION" iam create-user --user-name "$USER" >/dev/null

POLICY_ARN="$(
	aws --endpoint-url "$IAM_EP" --region "$REGION" iam create-policy \
		--policy-name "$POLICY_NAME-$USER" \
		--policy-document "file://${POLICY_DOC}" \
		--query 'Policy.Arn' --output text
)"

aws --endpoint-url "$IAM_EP" --region "$REGION" iam attach-user-policy \
	--user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null

KEYS_JSON="$(
	aws --endpoint-url "$IAM_EP" --region "$REGION" iam create-access-key \
		--user-name "$USER" --output json
)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

set +e
OUT="$(
	AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
		aws --endpoint-url "$IAM_EP" --region "$REGION" s3 ls 2>&1
)"
RC=$?
set -e

if [[ "$RC" -eq 0 ]]; then
	echo "FAIL: expected AccessDenied, but s3 ls succeeded" >&2
	echo "$OUT" >&2
	exit 1
fi

if ! echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|UnauthorizedOperation'; then
	echo "FAIL: expected AccessDenied in output:" >&2
	echo "$OUT" >&2
	exit 1
fi

echo "OK: AccessDenied for deny-policy user (s3 ls)"
echo "$OUT" | head -3
