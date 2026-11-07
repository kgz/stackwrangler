#!/usr/bin/env bash
# iam:PermissionsBoundary request condition key (#525).
# Happy: CreateRole with matching --permissions-boundary allowed.
# Sad: CreateRole without boundary denied; AttachRolePolicy on a role
#      without that boundary denied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_SESSION_TOKEN
TS="$(date +%s)"
KEEP="${AWSBOX_IAM_BOUNDARY_KEEP:-0}"
ACCT="000000000000"
BOUNDARY_NAME="awsbox-pb-bound-${TS}"
DEPLOY_ROLE="awsbox-pb-deploy-${TS}"
APP_ROLE="awsbox-pb-app-${TS}"
NOB_ROLE="awsbox-pb-nob-${TS}"
BOUNDARY_ARN=""
ADMIN_KEY="$AWS_ACCESS_KEY_ID"
ADMIN_SECRET="$AWS_SECRET_ACCESS_KEY"
WORK="${TMPDIR:-/tmp}/awsbox-pb-$$"
mkdir -p "$WORK"
aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	rm -rf "$WORK"
	[[ "$KEEP" == "1" ]] && return 0
	unset AWS_SESSION_TOKEN
	export AWS_ACCESS_KEY_ID="$ADMIN_KEY"
	export AWS_SECRET_ACCESS_KEY="$ADMIN_SECRET"
	for role in "$APP_ROLE" "$NOB_ROLE" "$DEPLOY_ROLE"; do
		[[ -z "$role" ]] && continue
		aws iam delete-role-policy --role-name "$role" --policy-name allow >/dev/null 2>&1 || true
		for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null || true); do
			[[ -n "$arn" && "$arn" != "None" ]] && aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" >/dev/null 2>&1 || true
		done
		aws iam delete-role --role-name "$role" >/dev/null 2>&1 || true
	done
	[[ -n "$BOUNDARY_ARN" ]] && aws iam delete-policy --policy-arn "$BOUNDARY_ARN" >/dev/null 2>&1 || true
}
trap cleanup EXIT

expect_deny() {
	local label="$1" outfile="$2"
	local rc
	rc="$(cat "$outfile.rc")"
	[[ "$rc" -ne 0 ]] || { echo "FAIL: ${label} succeeded" >&2; cat "$outfile" >&2; exit 1; }
	grep -qiE 'AccessDenied|not authorized|ExplicitDeny' "$outfile" \
		|| { echo "FAIL: ${label}: $(cat "$outfile")" >&2; exit 1; }
	echo "OK: ${label}"
}

# Managed boundary the deploy role may (and must) attach.
cat >"$WORK/boundary.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": "*"
  }]
}
EOF
BOUNDARY_ARN="$(aws iam create-policy \
	--policy-name "$BOUNDARY_NAME" \
	--policy-document "file://$WORK/boundary.json" \
	--query Policy.Arn --output text)"

# Deploy role: CreateRole / AttachRolePolicy only with that boundary.
cat >"$WORK/deploy-trust.json" <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::000000000000:root"},
    "Action": "sts:AssumeRole"
  }]
}
EOF
aws iam create-role \
	--role-name "$DEPLOY_ROLE" \
	--assume-role-policy-document "file://$WORK/deploy-trust.json" >/dev/null

cat >"$WORK/deploy-inline.json" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iam:CreateRole",
      "Resource": "arn:aws:iam::${ACCT}:role/awsbox-pb-app-*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "${BOUNDARY_ARN}"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "iam:AttachRolePolicy",
      "Resource": "arn:aws:iam::${ACCT}:role/awsbox-pb-*",
      "Condition": {
        "StringEquals": {
          "iam:PermissionsBoundary": "${BOUNDARY_ARN}"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": "arn:aws:iam::${ACCT}:role/${DEPLOY_ROLE}"
    }
  ]
}
EOF
aws iam put-role-policy \
	--role-name "$DEPLOY_ROLE" \
	--policy-name allow \
	--policy-document "file://$WORK/deploy-inline.json" >/dev/null

# Role without a boundary — AttachRolePolicy as deployer must deny.
aws iam create-role \
	--role-name "$NOB_ROLE" \
	--assume-role-policy-document "file://$WORK/deploy-trust.json" >/dev/null

CREDS="$(aws sts assume-role \
	--role-arn "arn:aws:iam::${ACCT}:role/${DEPLOY_ROLE}" \
	--role-session-name pb-smoke \
	--query 'Credentials' --output json)"
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY
export AWS_SESSION_TOKEN
AWS_ACCESS_KEY_ID="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["AccessKeyId"])' <<<"$CREDS")"
AWS_SECRET_ACCESS_KEY="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SecretAccessKey"])' <<<"$CREDS")"
AWS_SESSION_TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["SessionToken"])' <<<"$CREDS")"

# Deny: create-role without permissions boundary.
set +e
aws iam create-role \
	--role-name "$APP_ROLE" \
	--assume-role-policy-document "file://$WORK/deploy-trust.json" \
	>"$WORK/create-nob.out" 2>&1
echo $? >"$WORK/create-nob.out.rc"
set -e
expect_deny "create-role without PermissionsBoundary denied" "$WORK/create-nob.out"

# Allow: create-role with matching boundary.
aws iam create-role \
	--role-name "$APP_ROLE" \
	--assume-role-policy-document "file://$WORK/deploy-trust.json" \
	--permissions-boundary "$BOUNDARY_ARN" >/dev/null
echo "OK: create-role with matching PermissionsBoundary allowed"

# Deny: attach to a role that has no boundary (key absent / mismatch).
set +e
aws iam attach-role-policy \
	--role-name "$NOB_ROLE" \
	--policy-arn "$BOUNDARY_ARN" \
	>"$WORK/attach-nob.out" 2>&1
echo $? >"$WORK/attach-nob.out.rc"
set -e
expect_deny "attach-role-policy on role without boundary denied" "$WORK/attach-nob.out"

# Allow: attach to the role that carries the matching boundary.
aws iam attach-role-policy \
	--role-name "$APP_ROLE" \
	--policy-arn "$BOUNDARY_ARN" >/dev/null
echo "OK: attach-role-policy on role with matching boundary allowed"

# Switch back to admin for cleanup of role session leftovers.
unset AWS_SESSION_TOKEN
export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"

echo "OK: iam:PermissionsBoundary condition key smoke"
