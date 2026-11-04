#!/usr/bin/env bash
# Transfer SFTP → LocalEmu S3 via native SSH-key auth (#141).
# Prefer ./bin/transfer-key-smoke.sh (wrong-key + S3→Lambda). This script is the
# short put→object check without the event Lambda.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
BUCKET="awsbox-xfer-dp-${TS}"
ROLE="awsbox-xfer-dp-role-${TS}"
USER="sftpuser"
SFTP_HOST="${AWSBOX_SFTP_HOST:-127.0.0.1}"
SFTP_PORT="${AWSBOX_SFTP_PORT:-${AWSBOX_SFTP_HOST_PORT:-2222}}"
KEEP="${AWSBOX_TRANSFER_KEEP:-0}"
TMP="$(mktemp -d)"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "${SID:-}" ]] && aws transfer delete-user --server-id "$SID" --user-name "$USER" >/dev/null 2>&1 || true
	[[ -n "${SID:-}" ]] && aws transfer delete-server --server-id "$SID" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name s3-home >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v sftp >/dev/null || {
	echo "FAIL: sftp client required" >&2
	exit 1
}
command -v ssh-keygen >/dev/null || {
	echo "FAIL: ssh-keygen required" >&2
	exit 1
}

cd "$ROOT"

echo "waiting for Transfer SFTP on ${SFTP_HOST}:${SFTP_PORT}…"
for _ in $(seq 1 60); do
	if timeout 1 bash -c "echo >/dev/tcp/${SFTP_HOST}/${SFTP_PORT}" 2>/dev/null; then
		break
	fi
	sleep 1
done

ssh-keygen -t ed25519 -N "" -f "$TMP/id" -C "awsbox-dp-${TS}" >/dev/null
PUB="$(cat "$TMP/id.pub")"

aws s3 mb "s3://${BUCKET}"
aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
	"Version":"2012-10-17",
	"Statement":[{"Effect":"Allow","Principal":{"Service":"transfer.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' >/dev/null
aws iam put-role-policy --role-name "$ROLE" --policy-name s3-home --policy-document "{
	\"Version\":\"2012-10-17\",
	\"Statement\":[{
		\"Effect\":\"Allow\",
		\"Action\":[\"s3:ListBucket\",\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],
		\"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]
	}]
}" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query Role.Arn --output text)"

SID="$(aws transfer create-server --protocols SFTP --identity-provider-type SERVICE_MANAGED \
	--query ServerId --output text)"
echo "transfer server: ${SID}"
aws transfer create-user --server-id "$SID" --user-name "$USER" --role "$ROLE_ARN" \
	--home-directory "/${BUCKET}" --home-directory-type PATH >/dev/null
aws transfer import-ssh-public-key --server-id "$SID" --user-name "$USER" \
	--ssh-public-key-body "$PUB" >/dev/null

PAYLOAD="$TMP/hello.txt"
echo "awsbox transfer dataplane ${TS}" >"$PAYLOAD"
REMOTE="inbox/hello-${TS}.txt"

sftp -i "$TMP/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o PreferredAuthentications=publickey -o PasswordAuthentication=no \
	-o BatchMode=yes -P "$SFTP_PORT" "${USER}@${SFTP_HOST}" >/dev/null <<EOF
put ${PAYLOAD} ${REMOTE}
bye
EOF

aws s3 cp "s3://${BUCKET}/${REMOTE}" "$TMP/out.txt" >/dev/null
grep -q "awsbox transfer dataplane ${TS}" "$TMP/out.txt"

echo "OK: SFTP key put → LocalEmu s3://${BUCKET}/${REMOTE} (native; see docs/transfer.md)"
