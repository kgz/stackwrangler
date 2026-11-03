#!/usr/bin/env bash
# REAL AWS only (~$0 IAM). Does not source local-emu-env.sh.
# Requires explicit human approval per docs/aws-parity-agent-iam.md / cost rule.
# Real AWS (~$0 IAM): temp deny-user → s3 ls AccessDenied; temp role → SimulatePrincipalPolicy Deny s3:PutObject.
# Uses default credentials (unset AWS_* local overrides). Requires create/delete IAM on that principal.
# Usage: ./bin/aws-parity-iam-denied.sh
set -euo pipefail

# Local stack keys in the shell must not override ~/.aws/credentials [default]
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
unset AWS_PROFILE AWS_DEFAULT_PROFILE
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-ap-southeast-2}"

PREFIX="awsbox-parity-$(date +%s)"
USER="${PREFIX}-deny"
ROLE="${PREFIX}-lambda"
POLICY_NAME="${PREFIX}-deny-s3"
TMPDIR="${TMPDIR:-/tmp}"
POLICY_DOC="${TMPDIR}/${PREFIX}-deny.json"
TRUST_DOC="${TMPDIR}/${PREFIX}-trust.json"
DENIED_KEY=""
POLICY_ARN=""
ACCOUNT=""

cleanup() {
	rm -f "$POLICY_DOC" "$TRUST_DOC"
	if [[ -n "$DENIED_KEY" ]]; then
		aws iam delete-access-key --user-name "$USER" --access-key-id "$DENIED_KEY" 2>/dev/null || true
	fi
	if [[ -n "$POLICY_ARN" ]]; then
		aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" 2>/dev/null || true
		aws iam delete-policy --policy-arn "$POLICY_ARN" 2>/dev/null || true
	fi
	aws iam delete-user --user-name "$USER" 2>/dev/null || true
	aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> caller"
aws sts get-caller-identity
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"

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

cat >"$TRUST_DOC" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

echo "==> create deny user + policy"
aws iam create-user --user-name "$USER" \
	--tags Key=awsbox-parity,Value=1 >/dev/null

POLICY_ARN="$(
	aws iam create-policy \
		--policy-name "$POLICY_NAME" \
		--policy-document "file://${POLICY_DOC}" \
		--query 'Policy.Arn' --output text
)"

aws iam attach-user-policy --user-name "$USER" --policy-arn "$POLICY_ARN" >/dev/null

KEYS_JSON="$(aws iam create-access-key --user-name "$USER" --output json)"
DENIED_KEY="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["AccessKeyId"])')"
DENIED_SECRET="$(echo "$KEYS_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKey"]["SecretAccessKey"])')"

echo "==> deny-user s3 ls (expect AccessDenied; wait for key prop)"
OUT=""
RC=1
for _ in $(seq 1 30); do
	set +e
	OUT="$(
		AWS_ACCESS_KEY_ID="$DENIED_KEY" AWS_SECRET_ACCESS_KEY="$DENIED_SECRET" \
			AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" \
			aws s3 ls 2>&1
	)"
	RC=$?
	set -e
	# Key not visible yet — retry
	if echo "$OUT" | grep -qiE 'InvalidAccessKeyId|does not exist in our records'; then
		sleep 2
		continue
	fi
	break
done

if [[ "$RC" -eq 0 ]]; then
	echo "FAIL: expected AccessDenied, but s3 ls succeeded" >&2
	echo "$OUT" >&2
	exit 1
fi
if ! echo "$OUT" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|Unauthorized'; then
	echo "FAIL: expected AccessDenied in output:" >&2
	echo "$OUT" >&2
	exit 1
fi
echo "OK: deny-user AccessDenied"
echo "$OUT" | head -2

echo "==> create empty lambda role + simulate PutObject"
aws iam create-role \
	--role-name "$ROLE" \
	--assume-role-policy-document "file://${TRUST_DOC}" \
	--tags Key=awsbox-parity,Value=1 >/dev/null

ROLE_ARN="arn:aws:iam::${ACCOUNT}:role/${ROLE}"
set +e
SIM="$(
	aws iam simulate-principal-policy \
		--policy-source-arn "$ROLE_ARN" \
		--action-names s3:PutObject \
		--resource-arns "arn:aws:s3:::awsbox-parity-probe-bucket/key" \
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
d=json.load(sys.stdin)
print(d["EvaluationResults"][0]["EvalDecision"])
')"
if [[ "$DECISION" != "implicitDeny" && "$DECISION" != "explicitDeny" && "$DECISION" != "denied" ]]; then
	echo "FAIL: expected deny decision for empty role, got: $DECISION" >&2
	echo "$SIM" >&2
	exit 1
fi
echo "OK: empty role SimulatePrincipalPolicy → $DECISION"
echo "OK: real-AWS IAM parity ($PREFIX)"
