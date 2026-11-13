#!/usr/bin/env bash
# #713: after LocalEmu recreate with PERSISTENCE=1, UpdateFunctionCode must
# replace a restored function when the zip in awslambda-*-tasks was lost
# (no version manager), and delete-function must clear the leftover.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EMU="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
FN="sw-persist-lambda-${TS}"
ROLE_NAME="sw-persist-lambda-role-${TS}"
VOL="sw-persist-lambda-vol-${TS}"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")
OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/sw-persist-lambda-XXXXXX.yml")"
ZIP1="$(mktemp "${TMPDIR:-/tmp}/sw-persist-lambda-XXXXXX.zip")"
ZIP2="$(mktemp "${TMPDIR:-/tmp}/sw-persist-lambda-XXXXXX.zip")"
OUT="$(mktemp "${TMPDIR:-/tmp}/sw-persist-lambda-XXXXXX.json")"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws_emu() {
	command aws --endpoint-url "$EMU" --region "$REGION" \
		--cli-connect-timeout 10 --cli-read-timeout 60 "$@"
}

cleanup() {
	aws_emu lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws_emu iam delete-role --role-name "$ROLE_NAME" >/dev/null 2>&1 || true
	rm -f "$ZIP1" "$ZIP2" "$OUT"
	# Drop override first so recreate does not keep the named persist volume.
	rm -f "$OVERRIDE"
	"${COMPOSE[@]}" up -d --force-recreate --no-deps localstack >/dev/null 2>&1 || true
	docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

make_zip() {
	local path="$1"
	local marker="$2"
	python3 - <<PY
import zipfile
code = b"""exports.handler = async () => ({ marker: "${marker}" });
"""
with zipfile.ZipFile("${path}", "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY
}

wait_ready() {
	# Prefer /_localemu/health — any HTTP on / races mid --force-recreate
	# (dying gateway still answers; create then lands on a wiped process →
	# get-function empty State for the whole wait_state loop).
	local body=""
	for _ in $(seq 1 90); do
		body="$(curl -sf --max-time 2 "$EMU/_localemu/health" 2>/dev/null || true)"
		if [[ "$body" == *'"services"'* ]]; then
			if aws_emu iam list-roles --max-items 1 >/dev/null 2>&1 \
				&& aws_emu lambda list-functions --max-items 1 >/dev/null 2>&1; then
				return 0
			fi
		fi
		sleep 2
	done
	echo "FAIL: LocalEmu not ready (health/IAM/Lambda)" >&2
	return 1
}

wait_state() {
	local want="$1"
	local st=""
	local err=""
	local out=""
	for _ in $(seq 1 90); do
		if out="$(aws_emu lambda get-function --function-name "$FN" \
			--query 'Configuration.State' --output text 2>&1)"; then
			st="$out"
			[[ "$st" == "$want" ]] && return 0
		else
			err="$out"
			st=""
		fi
		sleep 2
	done
	echo "FAIL: State=${st:-empty} want=${want} last=${err:-none}" >&2
	return 1
}

# Drop persisted S3 bodies (incl. awslambda-*-tasks zips) while keeping
# Lambda API state so recreate hits the unrestored / no-manager path (#713).
wipe_persisted_s3_bodies() {
	# Reuse the LocalEmu image (already pulled) as a scratch fs tool.
	local img left
	img="$("${COMPOSE[@]}" config --images 2>/dev/null | awk '/localemu/{print; exit}')"
	[[ -n "$img" ]] || img="localemu/localemu:latest"
	docker run --rm --entrypoint sh -v "${VOL}:/var/lib/localemu" "$img" -c '
		set -e
		find /var/lib/localemu -type d -name s3_bodies -exec rm -rf {} + 2>/dev/null || true
		find /var/lib/localemu -type f -name s3_bodies.state -delete 2>/dev/null || true
		# Recreate empty dirs so persistence layout stays familiar.
		mkdir -p /var/lib/localemu/state/state/assets/s3_bodies
	' >/dev/null
	left="$(docker run --rm --entrypoint sh -v "${VOL}:/var/lib/localemu" "$img" -c \
		'find /var/lib/localemu -type f -path "*/s3_bodies/*" 2>/dev/null | wc -l')"
	[[ "${left// /}" == "0" ]] || {
		echo "FAIL: s3_bodies wipe left ${left} file(s)" >&2
		return 1
	}
}

recreate_localemu() {
	"${COMPOSE[@]}" -f "$OVERRIDE" stop localstack >/dev/null
	wipe_persisted_s3_bodies
	"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
	wait_ready
}

cat >"$OVERRIDE" <<EOF
services:
  localstack:
    environment:
      PERSISTENCE: "1"
      # Prompt Failed marking once s3_bodies are wiped (default 45s).
      AWSBOX_LAMBDA_PERSIST_CODE_WAIT_S: "2"
      STACKWRANGLER_LAMBDA_PERSIST_CODE_WAIT_S: "2"
    volumes:
      - persist_localemu:/var/lib/localemu
volumes:
  persist_localemu:
    name: ${VOL}
EOF

echo "== #713 PERSISTENCE=1 recreate volume ${VOL} =="
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
wait_ready

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws_emu iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws_emu iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text)"

make_zip "$ZIP1" "before"
aws_emu lambda create-function \
	--function-name "$FN" \
	--runtime nodejs18.x \
	--role "$ROLE_ARN" \
	--handler index.handler \
	--zip-file "fileb://${ZIP1}" >/dev/null
wait_state Active

aws_emu lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
	"$OUT" >/dev/null
grep -q '"marker": *"before"\|"marker":"before"' "$OUT" || {
	echo "FAIL: pre-recreate invoke: $(cat "$OUT")" >&2
	exit 1
}
echo "OK: invoke before recreate"

# Flush ON_SHUTDOWN save, wipe code bodies, recreate (metadata stays).
recreate_localemu

aws_emu lambda get-function --function-name "$FN" \
	--query 'Configuration.FunctionName' --output text | grep -qx "$FN"
wait_state Failed
REASON="$(aws_emu lambda get-function --function-name "$FN" \
	--query 'Configuration.StateReason' --output text 2>/dev/null || true)"
echo "OK: State=Failed after recreate with wiped s3_bodies (reason=${REASON:-empty})"

make_zip "$ZIP2" "after"
# #713: no running manager → UpdateFunctionCode must create, not ValueError.
aws_emu lambda update-function-code \
	--function-name "$FN" --zip-file "fileb://${ZIP2}" >/dev/null
wait_state Active
echo "OK: UpdateFunctionCode after Failed restore"

aws_emu lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out \
	"$OUT" >/dev/null
grep -q '"marker": *"after"\|"marker":"after"' "$OUT" || {
	echo "FAIL: post-update invoke: $(cat "$OUT")" >&2
	exit 1
}
echo "OK: invoke after UpdateFunctionCode"

# Second unrestored cycle: delete must succeed with no version manager.
recreate_localemu
wait_state Failed
echo "OK: State=Failed again (no manager) before delete"

aws_emu lambda delete-function --function-name "$FN" >/dev/null
if aws_emu lambda get-function --function-name "$FN" >/dev/null 2>&1; then
	echo "FAIL: function still present after delete" >&2
	exit 1
fi
echo "OK: delete-function with no version manager"

# Recreate same name must succeed (no leftover).
aws_emu lambda create-function \
	--function-name "$FN" \
	--runtime nodejs18.x \
	--role "$ROLE_ARN" \
	--handler index.handler \
	--zip-file "fileb://${ZIP2}" >/dev/null
wait_state Active
echo "OK: recreate same name after delete"

echo "OK: Lambda UpdateFunctionCode / delete survive unrestored PERSISTENCE recreate (#713)"
