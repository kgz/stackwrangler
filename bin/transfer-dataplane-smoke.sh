#!/usr/bin/env bash
# SFTP put via awsbox sidecar → object in LocalEmu S3 (Transfer API stays control-plane).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
BUCKET="awsbox-xfer-dp-${TS}"
KEY_NAME="inbox/hello-${TS}.txt"
SFTP_HOST="${AWSBOX_SFTP_HOST:-127.0.0.1}"
SFTP_PORT="${AWSBOX_SFTP_PORT:-2222}"
SFTP_USER="${AWSBOX_SFTP_USER:-awsbox}"
SFTP_PASS="${AWSBOX_SFTP_PASS:-awsboxpass}"
KEEP="${AWSBOX_TRANSFER_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${AWSBOX_REGION:-us-east-1}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

command -v sshpass >/dev/null || {
	echo "FAIL: sshpass required (apt install sshpass)" >&2
	exit 1
}
command -v sftp >/dev/null || {
	echo "FAIL: sftp client required" >&2
	exit 1
}

cd "$ROOT"
docker compose up -d sftp >/dev/null

echo "waiting for SFTP on ${SFTP_HOST}:${SFTP_PORT}…"
for _ in $(seq 1 30); do
	if timeout 1 bash -c "echo >/dev/tcp/${SFTP_HOST}/${SFTP_PORT}" 2>/dev/null; then
		break
	fi
	sleep 1
done

PAYLOAD="$(mktemp)"
RECV="$(mktemp)"
cleanup() {
	rm -f "$PAYLOAD" "$RECV" "$RECV.out"
	[[ "$KEEP" == "1" ]] && return 0
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "awsbox transfer dataplane ${TS}" >"$PAYLOAD"

# Control-plane Transfer server (IaC shape) — LocalEmu has no SFTP listen yet.
SID="$(aws transfer create-server \
	--protocols SFTP \
	--identity-provider-type SERVICE_MANAGED \
	--query 'ServerId' --output text)"
echo "transfer server (API): ${SID}"

aws s3 mb "s3://${BUCKET}"

# Avoid sftp -b + sshpass auth quirks — feed commands on stdin.
sshpass -p "$SFTP_PASS" sftp \
	-o StrictHostKeyChecking=no \
	-o UserKnownHostsFile=/dev/null \
	-o PreferredAuthentications=password \
	-o PubkeyAuthentication=no \
	-P "$SFTP_PORT" "${SFTP_USER}@${SFTP_HOST}" >/dev/null <<EOF
put ${PAYLOAD} upload/hello-${TS}.txt
bye
EOF

# Bridge: copy from SFTP container inbox → LocalEmu S3 (emulator has no data plane).
CID="$(docker compose ps -q sftp)"
docker cp "${CID}:/home/awsbox/upload/hello-${TS}.txt" "$RECV"
grep -q "awsbox transfer dataplane ${TS}" "$RECV"

aws s3 cp "$RECV" "s3://${BUCKET}/${KEY_NAME}" >/dev/null
aws s3 cp "s3://${BUCKET}/${KEY_NAME}" "$RECV.out" >/dev/null
grep -q "awsbox transfer dataplane ${TS}" "$RECV.out"

[[ "$KEEP" == "1" ]] || aws transfer delete-server --server-id "$SID" >/dev/null 2>&1 || true

echo "OK: SFTP put → LocalEmu s3://${BUCKET}/${KEY_NAME} (bridge; see docs/transfer.md)"
