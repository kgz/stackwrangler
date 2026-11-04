#!/usr/bin/env bash
# Transfer Family native SFTP SSH-key auth (#141).
# Slice: examples/serverless-v3-rest/slices/transfer-in
#
# Happy: ImportSshPublicKey → sftp -i put → object in S3 home → S3 event Lambda runs.
# Sad:   wrong private key rejected; no awsboxpass / sshpass on the happy path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
SFTP_HOST="${AWSBOX_SFTP_HOST:-127.0.0.1}"
SFTP_PORT="${AWSBOX_SFTP_PORT:-${AWSBOX_SFTP_HOST_PORT:-2222}}"
TS="$(date +%s)"
KEEP="${AWSBOX_TRANSFER_KEEP:-0}"
BUCKET="awsbox-xfer-in-${TS}"
ROLE="awsbox-xfer-in-role-${TS}"
USER="sftpuser"
SLICE="$ROOT/examples/serverless-v3-rest/slices/transfer-in"
TMP="$(mktemp -d)"
FAILS=0
FN="awsbox-xfer-in-fn-${TS}"
FN_ROLE="awsbox-xfer-in-fnrole-${TS}"
MARKER="awsbox-xfer-in-marker-${TS}"

export AWS_ACCESS_KEY_ID="${AWSBOX_ACCESS_KEY:-awsbox}"
export AWS_SECRET_ACCESS_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	[[ -n "${SID:-}" ]] && aws transfer delete-user --server-id "$SID" --user-name "$USER" >/dev/null 2>&1 || true
	[[ -n "${SID:-}" ]] && aws transfer delete-server --server-id "$SID" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	for r in "$FN_ROLE" "$ROLE"; do
		for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null); do
			aws iam delete-role-policy --role-name "$r" --policy-name "$p" >/dev/null 2>&1 || true
		done
		aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true
	done
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

check() {
	if [[ "$2" == 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); fi
}

command -v sftp >/dev/null || {
	echo "FAIL: sftp client required" >&2
	exit 1
}
command -v ssh-keygen >/dev/null || {
	echo "FAIL: ssh-keygen required" >&2
	exit 1
}
# Happy path must not need sshpass / awsboxpass.
if command -v sshpass >/dev/null 2>&1; then
	echo "note: sshpass present but unused (native key path)"
fi

cd "$ROOT"

echo "waiting for Transfer SFTP on ${SFTP_HOST}:${SFTP_PORT}…"
for _ in $(seq 1 60); do
	if timeout 1 bash -c "echo >/dev/tcp/${SFTP_HOST}/${SFTP_PORT}" 2>/dev/null; then
		break
	fi
	sleep 1
done
if ! timeout 1 bash -c "echo >/dev/tcp/${SFTP_HOST}/${SFTP_PORT}" 2>/dev/null; then
	echo "FAIL: no SFTP listener on ${SFTP_HOST}:${SFTP_PORT} (native Transfer — recreate LocalEmu after pull)" >&2
	exit 1
fi

ssh-keygen -t ed25519 -N "" -f "$TMP/id_ed25519" -C "awsbox-xfer-in-${TS}" >/dev/null
ssh-keygen -t ed25519 -N "" -f "$TMP/id_wrong" -C "awsbox-xfer-wrong-${TS}" >/dev/null
PUB="$(cat "$TMP/id_ed25519.pub")"

aws s3 mb "s3://${BUCKET}" >/dev/null

aws iam create-role --role-name "$ROLE" --assume-role-policy-document '{
	"Version":"2012-10-17",
	"Statement":[{
		"Effect":"Allow",
		"Principal":{"Service":"transfer.amazonaws.com"},
		"Action":"sts:AssumeRole"
	}]
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

# S3 → Lambda (slice handler) for ObjectCreated.
aws iam create-role --role-name "$FN_ROLE" --assume-role-policy-document '{
	"Version":"2012-10-17",
	"Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' >/dev/null
aws iam put-role-policy --role-name "$FN_ROLE" --policy-name inline --policy-document "{
	\"Version\":\"2012-10-17\",
	\"Statement\":[
		{\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"},
		{\"Effect\":\"Allow\",\"Action\":\"s3:PutObject\",\"Resource\":\"arn:aws:s3:::${BUCKET}/markers/*\"}
	]
}" >/dev/null
FN_ROLE_ARN="$(aws iam get-role --role-name "$FN_ROLE" --query Role.Arn --output text)"

python3 - "$SLICE/handler.js" "$TMP/slice.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[1], "handler.js")
PY

aws lambda create-function --function-name "$FN" --runtime nodejs20.x \
	--role "$FN_ROLE_ARN" --handler handler.main --zip-file "fileb://${TMP}/slice.zip" \
	--timeout 30 --environment "Variables={MARKER_BUCKET=${BUCKET},MARKER_KEY=markers/${MARKER}.txt}" \
	>/dev/null
for _ in $(seq 1 60); do
	[[ "$(aws lambda get-function --function-name "$FN" --query Configuration.State --output text 2>/dev/null || echo Pending)" == Active ]] && break
	sleep 1
done
FN_ARN="$(aws lambda get-function --function-name "$FN" --query Configuration.FunctionArn --output text)"
aws lambda add-permission --function-name "$FN" --statement-id s3invoke \
	--action lambda:InvokeFunction --principal s3.amazonaws.com \
	--source-arn "arn:aws:s3:::${BUCKET}" >/dev/null
aws s3api put-bucket-notification-configuration --bucket "$BUCKET" --notification-configuration "{
	\"LambdaFunctionConfigurations\":[{
		\"Id\":\"xfer-in\",
		\"LambdaFunctionArn\":\"${FN_ARN}\",
		\"Events\":[\"s3:ObjectCreated:*\"],
		\"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"prefix\",\"Value\":\"inbox/\"}]}}
	}]
}" >/dev/null

SID="$(aws transfer create-server --protocols SFTP --identity-provider-type SERVICE_MANAGED \
	--query ServerId --output text)"
aws transfer create-user --server-id "$SID" --user-name "$USER" --role "$ROLE_ARN" \
	--home-directory "/${BUCKET}" --home-directory-type PATH >/dev/null
aws transfer import-ssh-public-key --server-id "$SID" --user-name "$USER" \
	--ssh-public-key-body "$PUB" >/dev/null

DESC="$(aws transfer describe-user --server-id "$SID" --user-name "$USER" --output json)"
echo "$DESC" | grep -q "SshPublicKey" && check "ImportSshPublicKey visible on describe-user" 0 || check "ImportSshPublicKey visible on describe-user" 1

PAYLOAD="$TMP/hello.txt"
echo "awsbox transfer key ${TS}" >"$PAYLOAD"
REMOTE="inbox/hello-${TS}.txt"

# Wrong key must fail (no password fallback).
set +e
sftp -i "$TMP/id_wrong" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o PreferredAuthentications=publickey -o PasswordAuthentication=no \
	-o BatchMode=yes -P "$SFTP_PORT" "${USER}@${SFTP_HOST}" >/dev/null 2>"$TMP/wrong.err" <<EOF
put ${PAYLOAD} ${REMOTE}
bye
EOF
WRONG_RC=$?
set -e
[[ "$WRONG_RC" -ne 0 ]] && check "wrong SSH key rejected" 0 || check "wrong SSH key rejected" 1

# Happy key put.
set +e
sftp -i "$TMP/id_ed25519" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o PreferredAuthentications=publickey -o PasswordAuthentication=no \
	-o BatchMode=yes -P "$SFTP_PORT" "${USER}@${SFTP_HOST}" >/dev/null 2>"$TMP/ok.err" <<EOF
put ${PAYLOAD} ${REMOTE}
bye
EOF
OK_RC=$?
set -e
[[ "$OK_RC" -eq 0 ]] && check "SFTP key auth put" 0 || {
	check "SFTP key auth put" 1
	echo "---- sftp stderr ----" >&2
	cat "$TMP/ok.err" >&2 || true
}

GOT="$TMP/got.txt"
if aws s3 cp "s3://${BUCKET}/${REMOTE}" "$GOT" >/dev/null 2>&1 && grep -q "awsbox transfer key ${TS}" "$GOT"; then
	check "object in Transfer S3 home" 0
else
	check "object in Transfer S3 home" 1
fi

# Wait for S3 event Lambda marker.
MARK_OK=1
for _ in $(seq 1 45); do
	if aws s3 cp "s3://${BUCKET}/markers/${MARKER}.txt" "$TMP/marker.txt" >/dev/null 2>&1; then
		if grep -q "$REMOTE" "$TMP/marker.txt" 2>/dev/null; then
			MARK_OK=0
			break
		fi
	fi
	sleep 1
done
check "S3 event Lambda ran" "$MARK_OK"

# Ensure smoke did not invoke sshpass for the happy path.
if grep -R "sshpass\|awsboxpass" "$TMP" >/dev/null 2>&1; then
	check "no awsboxpass/sshpass in happy artifacts" 1
else
	check "no awsboxpass/sshpass in happy artifacts" 0
fi

if [[ "$FAILS" -ne 0 ]]; then
	echo "FAIL: transfer-key-smoke (${FAILS} checks)" >&2
	exit 1
fi
echo "OK: transfer-key-smoke server=${SID} s3://${BUCKET}/${REMOTE} (native SSH keys; see docs/transfer.md)"
