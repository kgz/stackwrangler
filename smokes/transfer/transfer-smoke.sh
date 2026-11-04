#!/usr/bin/env bash
# Create Transfer Family SFTP server + SERVICE_MANAGED user → LocalEmu S3 home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
BUCKET="awsbox-xfer-${TS}"
ROLE="awsbox-xfer-role-${TS}"
USER="sftpuser"
KEEP="${AWSBOX_TRANSFER_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${AWSBOX_REGION:-us-east-1}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "${SID:-}" ]] || return 0
	aws transfer delete-user --server-id "$SID" --user-name "$USER" >/dev/null 2>&1 || true
	aws transfer delete-server --server-id "$SID" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name s3-home >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

aws s3 mb "s3://${BUCKET}"

aws iam create-role \
	--role-name "$ROLE" \
	--assume-role-policy-document '{
		"Version":"2012-10-17",
		"Statement":[{
			"Effect":"Allow",
			"Principal":{"Service":"transfer.amazonaws.com"},
			"Action":"sts:AssumeRole"
		}]
	}' >/dev/null

aws iam put-role-policy \
	--role-name "$ROLE" \
	--policy-name s3-home \
	--policy-document "{
		\"Version\":\"2012-10-17\",
		\"Statement\":[{
			\"Effect\":\"Allow\",
			\"Action\":[\"s3:ListBucket\",\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],
			\"Resource\":[
				\"arn:aws:s3:::${BUCKET}\",
				\"arn:aws:s3:::${BUCKET}/*\"
			]
		}]
	}" >/dev/null

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

# LocalEmu list-servers / list-users may be empty; describe-* is authoritative.
DESC="$(aws transfer describe-user --server-id "$SID" --user-name "$USER")"
echo "$DESC" | grep -q "$USER"
echo "$DESC" | grep -q "$BUCKET"

SRV="$(aws transfer describe-server --server-id "$SID")"
echo "$SRV" | grep -q "$SID"

echo "OK: transfer SFTP server ${SID} user ${USER} home s3://${BUCKET}"
echo "Note: SFTP data plane / SSH auth may be stubbed — see docs/transfer.md"
