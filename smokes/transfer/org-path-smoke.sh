#!/usr/bin/env bash
# Org-path E2E (#781 / #91): SFTP put → Lambda → LocalEmu S3 → ECS → RDS row.
#
# Prefer examples/org-path or examples/terraform/org-path when present (#780);
# otherwise inline fixtures under smokes/transfer/fixtures/org-path/.
#
# S3 contract (#162): assert the path brain on LocalEmu :4566 / IAM endpoint.
# Fail clearly if the object is only visible on Seaweed :8333.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EMU="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
SEA="${STACKWRANGLER_ENDPOINT:-${AWSBOX_ENDPOINT:-http://127.0.0.1:8333}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
SFTP_HOST="${AWSBOX_SFTP_HOST:-127.0.0.1}"
SFTP_PORT="${AWSBOX_SFTP_PORT:-${AWSBOX_SFTP_HOST_PORT:-${STACKWRANGLER_SFTP_HOST_PORT:-2222}}}"
TS="$(date +%s)"
KEEP="${STACKWRANGLER_ORG_PATH_KEEP:-${AWSBOX_ORG_PATH_KEEP:-0}}"
FIXTURE="$ROOT/smokes/transfer/fixtures/org-path"
TMP="$(mktemp -d)"
FAILS=0

BUCKET="sw-orgpath-${TS}"
XFER_ROLE="sw-orgpath-xfer-${TS}"
FN="sw-orgpath-fn-${TS}"
FN_ROLE="sw-orgpath-fnrole-${TS}"
ECS_ROLE_OK="sw-orgpath-ecs-ok-${TS}"
ECS_ROLE_DENY="sw-orgpath-ecs-deny-${TS}"
CLUSTER="sw-orgpath-ecs-${TS}"
FAMILY_OK="sw-orgpath-worker-ok-${TS}"
FAMILY_DENY="sw-orgpath-worker-deny-${TS}"
IMAGE="sw-orgpath-worker:${TS}"
RDS_ID="sw-orgpath-rds-${TS}"
RDS_USER="orgpath"
RDS_PASS="OrgPathRds1!"
RDS_DB="orgpath"
MARKER="orgpath-${TS}"
SFTP_USER="sftpuser"
REMOTE="inbox/hello-${TS}.txt"
PROCESSED="processed/hello-${TS}.txt.json"
EXAMPLE_MODE="inline"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws_emu() { command aws --endpoint-url "$EMU" --region "$REGION" "$@"; }
aws_sea() { command aws --endpoint-url "$SEA" --region "$REGION" "$@"; }
aws() { aws_emu "$@"; }

check() {
	if [[ "$2" == 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; FAILS=$((FAILS + 1)); fi
}
fail() { echo "FAIL: $*" >&2; exit 1; }

resolve_example() {
	local d
	for d in \
		"$ROOT/examples/org-path" \
		"$ROOT/examples/terraform/org-path" \
		"$ROOT/examples/terraform/org-path-sftp-rds"; do
		if [[ -d "$d" && -f "$d/lambda/handler.js" ]]; then
			echo "$d"
			return 0
		fi
	done
	return 1
}

LAMBDA_SRC="$FIXTURE/lambda/handler.js"
if EXAMPLE_DIR="$(resolve_example)"; then
	EXAMPLE_MODE="example"
	LAMBDA_SRC="$EXAMPLE_DIR/lambda/handler.js"
	echo "using example stack fixtures: $EXAMPLE_DIR"
else
	echo "note: examples/org-path not present — inline fixtures (#780 should adopt smokes/transfer/fixtures/org-path layout)"
fi

TASK_OK=""
TASK_DENY=""
SID=""

cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	for t in "$TASK_OK" "$TASK_DENY"; do
		[[ -n "$t" ]] && aws ecs stop-task --cluster "$CLUSTER" --task "$t" >/dev/null 2>&1 || true
	done
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	[[ -n "$SID" ]] && aws transfer delete-user --server-id "$SID" --user-name "$SFTP_USER" >/dev/null 2>&1 || true
	[[ -n "$SID" ]] && aws transfer delete-server --server-id "$SID" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws rds delete-db-instance --db-instance-identifier "$RDS_ID" --skip-final-snapshot >/dev/null 2>&1 || true
	for r in "$XFER_ROLE" "$FN_ROLE" "$ECS_ROLE_OK" "$ECS_ROLE_DENY"; do
		for p in $(aws iam list-role-policies --role-name "$r" --query 'PolicyNames[]' --output text 2>/dev/null || true); do
			[[ -n "$p" && "$p" != "None" ]] && aws iam delete-role-policy --role-name "$r" --policy-name "$p" >/dev/null 2>&1 || true
		done
		aws iam delete-role --role-name "$r" >/dev/null 2>&1 || true
	done
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	docker rmi "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v sftp >/dev/null || fail "sftp client required"
command -v ssh-keygen >/dev/null || fail "ssh-keygen required"
command -v psql >/dev/null || fail "psql required for RDS assert"
command -v docker >/dev/null || fail "docker required for ECS worker image"

cd "$ROOT"

echo "waiting for Transfer SFTP on ${SFTP_HOST}:${SFTP_PORT}…"
for _ in $(seq 1 60); do
	if timeout 1 bash -c "echo >/dev/tcp/${SFTP_HOST}/${SFTP_PORT}" 2>/dev/null; then
		break
	fi
	sleep 1
done
if ! timeout 1 bash -c "echo >/dev/tcp/${SFTP_HOST}/${SFTP_PORT}" 2>/dev/null; then
	fail "no SFTP listener on ${SFTP_HOST}:${SFTP_PORT}"
fi

# --- RDS ---
aws rds create-db-instance \
	--db-instance-identifier "$RDS_ID" \
	--db-instance-class db.t3.micro \
	--engine postgres \
	--engine-version 16.3 \
	--master-username "$RDS_USER" \
	--master-user-password "$RDS_PASS" \
	--allocated-storage 20 \
	--db-name "$RDS_DB" >/dev/null

RDS_HOST=""
RDS_PORT=""
for _ in $(seq 1 90); do
	RDS_HOST="$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
		--query 'DBInstances[0].Endpoint.Address' --output text 2>/dev/null || true)"
	RDS_PORT="$(aws rds describe-db-instances --db-instance-identifier "$RDS_ID" \
		--query 'DBInstances[0].Endpoint.Port' --output text 2>/dev/null || true)"
	if [[ -n "$RDS_HOST" && "$RDS_HOST" != "None" && -n "$RDS_PORT" && "$RDS_PORT" != "None" ]]; then
		if [[ "$RDS_HOST" == "localhost" || "$RDS_HOST" == "127.0.0.1" ]]; then
			break
		fi
		if docker ps --format '{{.Names}}' | grep -q "localemu-rds-${RDS_ID}"; then
			RDS_HOST=127.0.0.1
			break
		fi
	fi
	sleep 2
done
[[ -n "$RDS_PORT" && "$RDS_PORT" != "None" ]] || fail "no RDS endpoint port (RDS_DOCKER_BACKEND=1?)"
RDS_HOST="${RDS_HOST:-127.0.0.1}"
[[ "$RDS_HOST" == *rds.amazonaws.com ]] && RDS_HOST=127.0.0.1

echo "waiting for postgres on ${RDS_HOST}:${RDS_PORT}…"
for _ in $(seq 1 60); do
	if PGPASSWORD="$RDS_PASS" psql -h "$RDS_HOST" -p "$RDS_PORT" -U "$RDS_USER" -d "$RDS_DB" -c 'SELECT 1' >/dev/null 2>&1; then
		break
	fi
	sleep 2
done
PGPASSWORD="$RDS_PASS" psql -h "$RDS_HOST" -p "$RDS_PORT" -U "$RDS_USER" -d "$RDS_DB" -v ON_ERROR_STOP=1 <<SQL
CREATE TABLE IF NOT EXISTS org_path_ingest (
  id serial PRIMARY KEY,
  marker text NOT NULL,
  source_key text NOT NULL,
  note text NOT NULL,
  UNIQUE (marker, note)
);
SQL

# --- S3 + Transfer + Lambda ---
ssh-keygen -t ed25519 -N "" -f "$TMP/id_ed25519" -C "orgpath-${TS}" >/dev/null
PUB="$(cat "$TMP/id_ed25519.pub")"

aws s3 mb "s3://${BUCKET}" >/dev/null

aws iam create-role --role-name "$XFER_ROLE" --assume-role-policy-document '{
	"Version":"2012-10-17",
	"Statement":[{"Effect":"Allow","Principal":{"Service":"transfer.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' >/dev/null
aws iam put-role-policy --role-name "$XFER_ROLE" --policy-name s3-home --policy-document "{
	\"Version\":\"2012-10-17\",
	\"Statement\":[{
		\"Effect\":\"Allow\",
		\"Action\":[\"s3:ListBucket\",\"s3:GetObject\",\"s3:PutObject\",\"s3:DeleteObject\"],
		\"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]
	}]
}" >/dev/null
XFER_ROLE_ARN="$(aws iam get-role --role-name "$XFER_ROLE" --query Role.Arn --output text)"

aws iam create-role --role-name "$FN_ROLE" --assume-role-policy-document '{
	"Version":"2012-10-17",
	"Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
}' >/dev/null
aws iam put-role-policy --role-name "$FN_ROLE" --policy-name inline --policy-document "{
	\"Version\":\"2012-10-17\",
	\"Statement\":[
		{\"Effect\":\"Allow\",\"Action\":[\"logs:CreateLogGroup\",\"logs:CreateLogStream\",\"logs:PutLogEvents\"],\"Resource\":\"*\"},
		{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${BUCKET}/*\"}
	]
}" >/dev/null
FN_ROLE_ARN="$(aws iam get-role --role-name "$FN_ROLE" --query Role.Arn --output text)"

python3 - "$LAMBDA_SRC" "$TMP/lambda.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[2], "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.write(sys.argv[1], "handler.js")
PY

aws lambda create-function --function-name "$FN" --runtime nodejs20.x \
	--role "$FN_ROLE_ARN" --handler handler.main --zip-file "fileb://${TMP}/lambda.zip" \
	--timeout 30 --environment "Variables={PATH_BUCKET=${BUCKET},PROCESSED_PREFIX=processed/,PATH_MARKER=${MARKER}}" \
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
		\"Id\":\"org-path\",
		\"LambdaFunctionArn\":\"${FN_ARN}\",
		\"Events\":[\"s3:ObjectCreated:*\"],
		\"Filter\":{\"Key\":{\"FilterRules\":[{\"Name\":\"prefix\",\"Value\":\"inbox/\"}]}}
	}]
}" >/dev/null

SID="$(aws transfer create-server --protocols SFTP --identity-provider-type SERVICE_MANAGED \
	--query ServerId --output text)"
aws transfer create-user --server-id "$SID" --user-name "$SFTP_USER" --role "$XFER_ROLE_ARN" \
	--home-directory "/${BUCKET}" --home-directory-type PATH >/dev/null
aws transfer import-ssh-public-key --server-id "$SID" --user-name "$SFTP_USER" \
	--ssh-public-key-body "$PUB" >/dev/null

PAYLOAD="$TMP/hello.txt"
echo "org-path e2e ${MARKER}" >"$PAYLOAD"

set +e
sftp -i "$TMP/id_ed25519" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
	-o PreferredAuthentications=publickey -o PasswordAuthentication=no \
	-o BatchMode=yes -P "$SFTP_PORT" "${SFTP_USER}@${SFTP_HOST}" >/dev/null 2>"$TMP/sftp.err" <<EOF
put ${PAYLOAD} ${REMOTE}
bye
EOF
SFTP_RC=$?
set -e
[[ "$SFTP_RC" -eq 0 ]] && check "SFTP put" 0 || {
	check "SFTP put" 1
	cat "$TMP/sftp.err" >&2 || true
}

# --- #162 path-brain assert ---
assert_path_brain() {
	local key="$1" label="$2"
	local emu_rc sea_rc emu_body
	set +e
	emu_body="$(aws_emu s3 cp "s3://${BUCKET}/${key}" - 2>"$TMP/emu.err")"
	emu_rc=$?
	aws_sea s3 cp "s3://${BUCKET}/${key}" - >/dev/null 2>"$TMP/sea.err"
	sea_rc=$?
	set -e
	if [[ "$emu_rc" -ne 0 && "$sea_rc" -eq 0 ]]; then
		echo "FAIL: ${label} only visible on Seaweed ${SEA}, not LocalEmu path brain ${EMU} — dual-S3 cross-wire (#162)" >&2
		cat "$TMP/emu.err" >&2 || true
		return 1
	fi
	if [[ "$emu_rc" -ne 0 ]]; then
		echo "FAIL: ${label} missing on LocalEmu path brain ${EMU}" >&2
		cat "$TMP/emu.err" >&2 || true
		return 1
	fi
	if [[ "$sea_rc" -eq 0 ]]; then
		echo "note: ${label} also readable on Seaweed (ok if brains unified); asserted LocalEmu ${EMU}"
	fi
	printf '%s' "$emu_body" >"$TMP/brain-body.txt"
	return 0
}

if assert_path_brain "$REMOTE" "inbox object"; then
	if grep -q "org-path e2e ${MARKER}" "$TMP/brain-body.txt"; then
		check "inbox object on LocalEmu :4566 path brain" 0
	else
		check "inbox object on LocalEmu :4566 path brain" 1
	fi
else
	check "inbox object on LocalEmu :4566 path brain" 1
fi

set +e
aws_sea s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1
SEA_HEAD=$?
set -e
if [[ "$SEA_HEAD" -eq 0 ]]; then
	echo "note: Seaweed head-bucket succeeded for ${BUCKET}; org-path asserts still use ${EMU}"
fi

# --- Lambda processed object ---
MARK_OK=1
for _ in $(seq 1 60); do
	if assert_path_brain "$PROCESSED" "processed object" 2>/dev/null; then
		if grep -q "$REMOTE" "$TMP/brain-body.txt" && grep -q "$MARKER" "$TMP/brain-body.txt"; then
			MARK_OK=0
			break
		fi
	fi
	sleep 1
done
check "Lambda wrote processed object on path brain" "$MARK_OK"

# --- ECS worker image ---
cat >"$TMP/Dockerfile" <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache aws-cli postgresql-client jq
EOF
docker build -t "$IMAGE" "$TMP" >/dev/null

TRUST_ECS='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ECS_ROLE_OK" --assume-role-policy-document "$TRUST_ECS" >/dev/null
aws iam put-role-policy --role-name "$ECS_ROLE_OK" --policy-name s3-read --policy-document "{
	\"Version\":\"2012-10-17\",
	\"Statement\":[{
		\"Effect\":\"Allow\",
		\"Action\":[\"s3:GetObject\",\"s3:ListBucket\"],
		\"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"]
	}]
}" >/dev/null
ECS_OK_ARN="$(aws iam get-role --role-name "$ECS_ROLE_OK" --query Role.Arn --output text)"

aws iam create-role --role-name "$ECS_ROLE_DENY" --assume-role-policy-document "$TRUST_ECS" >/dev/null
aws iam put-role-policy --role-name "$ECS_ROLE_DENY" --policy-name s3-deny-list-only --policy-document "{
	\"Version\":\"2012-10-17\",
	\"Statement\":[{
		\"Effect\":\"Allow\",
		\"Action\":[\"s3:ListBucket\"],
		\"Resource\":\"arn:aws:s3:::${BUCKET}\"
	}]
}" >/dev/null
ECS_DENY_ARN="$(aws iam get-role --role-name "$ECS_ROLE_DENY" --query Role.Arn --output text)"

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

register_worker() {
	local family="$1" role_arn="$2" note="$3"
	local cmd
	# host network: task-role FULL_URI on loopback + RDS on 127.0.0.1 (bridge DNAT race).
	cmd=$(cat <<CMD
set -e
# brief wait so host creds URI is ready
for i in 1 2 3 4 5; do
  [ -n "\${AWS_CONTAINER_CREDENTIALS_FULL_URI:-}\${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ] && break
  sleep 1
done
aws s3 cp "s3://${BUCKET}/${PROCESSED}" /tmp/job.json
SRC=\$(jq -r .sourceKey /tmp/job.json)
PGPASSWORD='${RDS_PASS}' psql -h 127.0.0.1 -p ${RDS_PORT} -U ${RDS_USER} -d ${RDS_DB} -v ON_ERROR_STOP=1 \
  -c "INSERT INTO org_path_ingest (marker, source_key, note) VALUES ('${MARKER}', '\$SRC', '${note}') ON CONFLICT (marker, note) DO NOTHING;"
echo "ORG_PATH_WORKER_OK note=${note}"
CMD
)
	local cdef
	cdef="$(IMAGE="$IMAGE" CMD="$cmd" python3 -c '
import json, os
print(json.dumps([{
  "name": "worker",
  "image": os.environ["IMAGE"],
  "essential": True,
  "memory": 256,
  "command": ["sh", "-c", os.environ["CMD"]],
}]))
')"
	aws ecs register-task-definition \
		--family "$family" \
		--network-mode host \
		--requires-compatibilities EC2 \
		--task-role-arn "$role_arn" \
		--container-definitions "$cdef" \
		>/dev/null
}

register_worker "$FAMILY_OK" "$ECS_OK_ARN" "happy"
register_worker "$FAMILY_DENY" "$ECS_DENY_ARN" "deny-no-s3-get"

wait_task_stop() {
	local arn="$1" name="" status=""
	for _ in $(seq 1 90); do
		status="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" \
			--query 'tasks[0].lastStatus' --output text 2>/dev/null || echo UNKNOWN)"
		name="$(docker ps -a --filter "label=localemu.task-arn=${arn}" --format '{{.Names}}' | head -1 || true)"
		if [[ "$status" == "STOPPED" ]]; then
			printf '%s' "$name"
			return 0
		fi
		sleep 2
	done
	printf '%s' "$name"
	return 1
}

TASK_OK="$(
	aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY_OK" --launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
[[ -n "$TASK_OK" && "$TASK_OK" != "None" ]] || fail "RunTask happy returned no taskArn"
echo "happy task=${TASK_OK}"

CTR_OK=""
if CTR_OK="$(wait_task_stop "$TASK_OK")"; then
	:
fi
EXIT_OK="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_OK" \
	--query 'tasks[0].containers[0].exitCode' --output text 2>/dev/null || echo '')"
LOG_OK=""
[[ -n "$CTR_OK" ]] && LOG_OK="$(docker logs "$CTR_OK" 2>&1 || true)"
if [[ "$EXIT_OK" == "0" ]] || echo "$LOG_OK" | grep -q "ORG_PATH_WORKER_OK note=happy"; then
	check "ECS happy worker ran" 0
else
	check "ECS happy worker ran" 1
	echo "---- happy task logs ----" >&2
	echo "$LOG_OK" >&2 || true
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_OK" >&2 || true
fi

ROW="$(PGPASSWORD="$RDS_PASS" psql -h "$RDS_HOST" -p "$RDS_PORT" -U "$RDS_USER" -d "$RDS_DB" -Atc \
	"SELECT source_key FROM org_path_ingest WHERE marker = '${MARKER}' AND note = 'happy'")"
[[ "$ROW" == "$REMOTE" ]] && check "RDS has happy ingest row" 0 || check "RDS has happy ingest row" 1

# --- Authz sad: ECS task role without s3:GetObject ---
TASK_DENY="$(
	aws ecs run-task --cluster "$CLUSTER" --task-definition "$FAMILY_DENY" --launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
[[ -n "$TASK_DENY" && "$TASK_DENY" != "None" ]] || fail "RunTask deny returned no taskArn"
echo "deny task=${TASK_DENY}"

CTR_DENY=""
if CTR_DENY="$(wait_task_stop "$TASK_DENY")"; then
	:
fi
EXIT_DENY="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_DENY" \
	--query 'tasks[0].containers[0].exitCode' --output text 2>/dev/null || echo '')"
LOG_DENY=""
[[ -n "$CTR_DENY" ]] && LOG_DENY="$(docker logs "$CTR_DENY" 2>&1 || true)"
DENY_OK=1
if [[ "$EXIT_DENY" != "0" ]] && ! echo "$LOG_DENY" | grep -q "ORG_PATH_WORKER_OK note=deny-no-s3-get"; then
	if echo "$LOG_DENY" | grep -qiE 'AccessDenied|not authorized|Forbidden|Unable to locate credentials|An error occurred'; then
		DENY_OK=0
	elif [[ "$EXIT_DENY" != "0" && "$EXIT_DENY" != "None" && -n "$EXIT_DENY" ]]; then
		DENY_OK=0
	fi
fi
check "ECS deny task role without s3:GetObject fails" "$DENY_OK"

DENY_ROW="$(PGPASSWORD="$RDS_PASS" psql -h "$RDS_HOST" -p "$RDS_PORT" -U "$RDS_USER" -d "$RDS_DB" -Atc \
	"SELECT count(*) FROM org_path_ingest WHERE marker = '${MARKER}' AND note = 'deny-no-s3-get'")"
[[ "$DENY_ROW" == "0" ]] && check "RDS has no deny-path row" 0 || check "RDS has no deny-path row" 1

if [[ "$FAILS" -ne 0 ]]; then
	echo "FAIL: org-path-smoke (${FAILS} checks) mode=${EXAMPLE_MODE}" >&2
	exit 1
fi
echo "OK: org-path-smoke SFTP→Lambda→LocalEmu S3→ECS→RDS marker=${MARKER} mode=${EXAMPLE_MODE}"
