#!/usr/bin/env bash
# Sad path: Transfer user role without s3:PutObject → SFTP put fails; object absent (#322).
# Also documents N/A: LOGICAL home refused at SFTP login; custom IdP not used for auth.
# Happy: ./smokes/transfer/transfer-dataplane-smoke.sh
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
SFTP_HOST="${AWSBOX_SFTP_HOST:-127.0.0.1}"
SFTP_PORT="${AWSBOX_SFTP_PORT:-${AWSBOX_SFTP_HOST_PORT:-2222}}"
TS="$(date +%s)"
BUCKET="awsbox-xfer-authz-${TS}"
ROLE="awsbox-xfer-noperm-${TS}"
USER="xfer-deny"
LOGICAL_USER="xfer-logical"
KEEP="${AWSBOX_TRANSFER_KEEP:-0}"
TMP="$(mktemp -d)"
SID=""
IDP_SID=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	if [[ -n "$SID" ]]; then
		aws transfer delete-user --server-id "$SID" --user-name "$USER" >/dev/null 2>&1 || true
		aws transfer delete-user --server-id "$SID" --user-name "$LOGICAL_USER" >/dev/null 2>&1 || true
		aws transfer delete-server --server-id "$SID" >/dev/null 2>&1 || true
	fi
	if [[ -n "$IDP_SID" ]]; then
		aws transfer delete-server --server-id "$IDP_SID" >/dev/null 2>&1 || true
	fi
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
if ! timeout 1 bash -c "echo >/dev/tcp/${SFTP_HOST}/${SFTP_PORT}" 2>/dev/null; then
	echo "FAIL: no SFTP listener on ${SFTP_HOST}:${SFTP_PORT}" >&2
	exit 1
fi

ssh-keygen -t ed25519 -N "" -f "$TMP/id" -C "awsbox-authz-${TS}" >/dev/null
PUB="$(cat "$TMP/id.pub")"

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
aws transfer import-ssh-public-key --server-id "$SID" --user-name "$USER" \
	--ssh-public-key-body "$PUB" >/dev/null

# Trust is transfer.amazonaws.com only — CLI cannot AssumeRole. Keep simulate as a
# control-plane probe alongside the SFTP-byte deny below.
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
echo "ok   simulate empty role → ${DECISION}"

PAYLOAD="$TMP/deny-me.txt"
REMOTE="inbox/deny-${TS}.txt"
echo "must-not-land ${TS}" >"$PAYLOAD"

set +e
SFTP_OUT="$(
	sftp -i "$TMP/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o PreferredAuthentications=publickey -o PasswordAuthentication=no \
		-o BatchMode=yes -P "$SFTP_PORT" "${USER}@${SFTP_HOST}" 2>&1 <<EOF
put ${PAYLOAD} ${REMOTE}
bye
EOF
)"
SFTP_RC=$?
set -e

# OpenSSH sftp batch often exits 0 even when put's CLOSE returns Permission denied.
if ! echo "$SFTP_OUT" | grep -qiE 'Permission denied|PermissionDenied'; then
	echo "FAIL: SFTP put missing clear Permission denied (rc=${SFTP_RC}):" >&2
	echo "$SFTP_OUT" >&2
	exit 1
fi
echo "ok   SFTP put Permission denied (empty role, rc=${SFTP_RC})"

set +e
HEAD_OUT="$(aws s3api head-object --bucket "$BUCKET" --key "$REMOTE" 2>&1)"
HEAD_RC=$?
set -e
if [[ "$HEAD_RC" -eq 0 ]]; then
	echo "FAIL: object present after denied put: s3://${BUCKET}/${REMOTE}" >&2
	exit 1
fi
echo "ok   object absent after denied put"

# LOGICAL HomeDirectoryMappings — API may store; native SFTP refuses login (#322 N/A).
aws transfer create-user \
	--server-id "$SID" \
	--user-name "$LOGICAL_USER" \
	--role "$ROLE_ARN" \
	--home-directory-type LOGICAL \
	--home-directory-mappings "Entry=/,Target=/${BUCKET}" >/dev/null
aws transfer import-ssh-public-key --server-id "$SID" --user-name "$LOGICAL_USER" \
	--ssh-public-key-body "$PUB" >/dev/null

set +e
LOGICAL_OUT="$(
	sftp -i "$TMP/id" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o PreferredAuthentications=publickey -o PasswordAuthentication=no \
		-o BatchMode=yes -P "$SFTP_PORT" "${LOGICAL_USER}@${SFTP_HOST}" 2>&1 <<EOF
ls
bye
EOF
)"
LOGICAL_RC=$?
set -e
if [[ "$LOGICAL_RC" -eq 0 ]]; then
	echo "FAIL: LOGICAL home user authenticated (LOGICAL not supported)" >&2
	echo "$LOGICAL_OUT" >&2
	exit 1
fi
echo "ok   LOGICAL home → SFTP login refused (N/A)"

# Custom / API Gateway / Directory IdP — create-server may accept the type for IaC
# shape, but inbound SFTP never invokes an IdP (SERVICE_MANAGED SSH keys only).
IDP_SID="$(aws transfer create-server \
	--protocols SFTP \
	--identity-provider-type API_GATEWAY \
	--identity-provider-details Url=https://example.invalid/transfer,InvocationRole="$ROLE_ARN" \
	--query 'ServerId' --output text)"
IDP_TYPE="$(aws transfer describe-server --server-id "$IDP_SID" --query 'Server.IdentityProviderType' --output text)"
if [[ "$IDP_TYPE" != "API_GATEWAY" ]]; then
	echo "FAIL: expected IdentityProviderType API_GATEWAY, got: $IDP_TYPE" >&2
	exit 1
fi
echo "ok   IdP API_GATEWAY stored for IaC; SFTP auth does not call IdP (N/A — see docs/transfer.md)"

echo "OK: Transfer role without s3:PutObject → SFTP put denied; object absent (server=${SID})"
