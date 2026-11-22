#!/usr/bin/env bash
# #742: Terraform S3 remote state + DynamoDB lock survive LocalEmu recreate
# under PERSISTENCE=1. Uses examples/terraform/stackwrangler-backend/.
# apply → recreate volume-backed LocalEmu → plan no-change; state object +
# lock table intact. Does not flip host --dev mode (unique volume, like
# persist-recreate-smoke / s3-persist-recreate-smoke).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOOT="$ROOT/examples/terraform/stackwrangler-backend/bootstrap"
APP="$ROOT/examples/terraform/stackwrangler-backend/app"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
SUFFIX="tfpersist-${TS}-$$"
STATE_BUCKET="sw-tf-state-${SUFFIX}"
LOCK_TABLE="sw-tf-locks-${SUFFIX}"
TOPIC="sw-tf-topic-${SUFFIX}"
STATE_KEY="stackwrangler-backend/app.tfstate"
VOL="sw-tf-persist-vol-${TS}"
PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$ROOT")}"
COMPOSE=(docker compose -p "$PROJECT" -f "$ROOT/docker-compose.yml")
OVERRIDE="$(mktemp "${TMPDIR:-/tmp}/sw-tf-persist-XXXXXX.yml")"
WORKDIR="${TMPDIR:-/tmp}/sw-tf-persist-smoke-$$"
PLUGIN_CACHE="${AWSBOX_TF_PLUGIN_CACHE:-$WORKDIR/plugin-cache}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	if [[ -d "$APP" ]]; then
		(
			cd "$APP"
			if [[ -d .terraform ]]; then
				terraform destroy -input=false -auto-approve \
					-var="awsbox_endpoint=${EP}" \
					-var="awsbox_access_key=${KEY}" \
					-var="awsbox_secret_key=${SECRET}" \
					-var="topic_name=${TOPIC}" >/dev/null 2>&1 || true
			fi
			rm -f backend_override.tf
			rm -rf .terraform terraform.tfstate terraform.tfstate.backup .terraform.lock.hcl
		)
	fi
	if [[ -d "$BOOT" ]]; then
		(
			cd "$BOOT"
			if [[ -d .terraform ]]; then
				terraform destroy -input=false -auto-approve \
					-var="awsbox_endpoint=${EP}" \
					-var="awsbox_access_key=${KEY}" \
					-var="awsbox_secret_key=${SECRET}" \
					-var="state_bucket=${STATE_BUCKET}" \
					-var="lock_table=${LOCK_TABLE}" >/dev/null 2>&1 || true
			fi
			rm -rf .terraform terraform.tfstate terraform.tfstate.backup .terraform.lock.hcl
		)
	fi
	# Drop persist override so hermetic PERSISTENCE=0 returns.
	"${COMPOSE[@]}" up -d --force-recreate --no-deps localstack >/dev/null 2>&1 || true
	rm -f "$OVERRIDE"
	rm -rf "$WORKDIR"
	docker volume rm -f "$VOL" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v terraform >/dev/null || fail "terraform is required"
command -v aws >/dev/null || fail "aws cli is required"
command -v python3 >/dev/null || fail "python3 is required"

host="$(
	AWSBOX_EP_CHECK="$EP" python3 - <<'PY'
from urllib.parse import urlparse
import os, sys
u = urlparse(os.environ["AWSBOX_EP_CHECK"])
host = (u.hostname or "").lower()
print(host)
if not host:
    sys.exit(2)
ok = host in ("127.0.0.1", "localhost", "::1") or host.endswith(".localhost")
sys.exit(0 if ok else 1)
PY
)" || fail "endpoint host must be loopback (got from ${EP})"

mkdir -p "$WORKDIR" "$PLUGIN_CACHE"
export TF_PLUGIN_CACHE_DIR="$PLUGIN_CACHE"

canary_env=(
	env -i
	HOME="$WORKDIR"
	PATH="/usr/bin:/bin:${PATH:-/usr/bin:/bin}"
	TERM="${TERM:-dumb}"
	LANG="${LANG:-C.UTF-8}"
	AWS_ACCESS_KEY_ID="$KEY"
	AWS_SECRET_ACCESS_KEY="$SECRET"
	AWS_DEFAULT_REGION="$REGION"
	AWS_REGION="$REGION"
	AWS_EC2_METADATA_DISABLED=true
	AWS_SHARED_CREDENTIALS_FILE="$WORKDIR/empty-creds"
	AWS_CONFIG_FILE="$WORKDIR/empty-config"
)
: >"$WORKDIR/empty-creds"
: >"$WORKDIR/empty-config"

set +e
canary_out="$("${canary_env[@]}" aws sts get-caller-identity 2>&1)"
canary_rc=$?
set -e
if [[ "$canary_rc" -eq 0 ]]; then
	echo "abort: canary sts get-caller-identity succeeded without a local endpoint" >&2
	echo "refusing to run — traffic would hit real AWS" >&2
	echo "$canary_out" >&2
	exit 1
fi
echo "canary: real AWS STS failed as expected (rc=${canary_rc})"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWS_EC2_METADATA_DISABLED=true
unset AWS_ENDPOINT_URL || true

aws_emu() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

wait_ready() {
	local code=""
	for _ in $(seq 1 90); do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$EP/" || true)"
		[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && return 0
		sleep 2
	done
	fail "LocalEmu not ready (${code:-none})"
}

cat >"$OVERRIDE" <<EOF
services:
  localstack:
    environment:
      PERSISTENCE: "1"
    volumes:
      - persist_localemu:/var/lib/localemu
volumes:
  persist_localemu:
    name: ${VOL}
EOF

echo "== persistence override (volume ${VOL}) =="
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
wait_ready

echo "bootstrap: bucket=${STATE_BUCKET} lock=${LOCK_TABLE}"
cd "$BOOT"
terraform init -input=false >/dev/null
terraform apply -input=false -auto-approve \
	-var="awsbox_endpoint=${EP}" \
	-var="awsbox_access_key=${KEY}" \
	-var="awsbox_secret_key=${SECRET}" \
	-var="state_bucket=${STATE_BUCKET}" \
	-var="lock_table=${LOCK_TABLE}"

AWSBOX_EP="$EP" AWSBOX_KEY="$KEY" AWSBOX_SECRET="$SECRET" \
	AWSBOX_BUCKET="$STATE_BUCKET" AWSBOX_LOCK="$LOCK_TABLE" AWSBOX_STATE_KEY="$STATE_KEY" \
	python3 - <<'PY' >"$APP/backend_override.tf"
import os
ep = os.environ["AWSBOX_EP"]
print(f'''terraform {{
  backend "s3" {{
    bucket         = "{os.environ["AWSBOX_BUCKET"]}"
    key            = "{os.environ["AWSBOX_STATE_KEY"]}"
    region         = "us-east-1"
    dynamodb_table = "{os.environ["AWSBOX_LOCK"]}"
    encrypt        = true

    access_key = "{os.environ["AWSBOX_KEY"]}"
    secret_key = "{os.environ["AWSBOX_SECRET"]}"

    endpoints = {{
      s3       = "{ep}"
      dynamodb = "{ep}"
      sts      = "{ep}"
    }}

    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
  }}
}}
''')
PY

echo "app: apply under remote state"
cd "$APP"
terraform init -input=false -reconfigure >/dev/null
terraform apply -input=false -auto-approve \
	-var="awsbox_endpoint=${EP}" \
	-var="awsbox_access_key=${KEY}" \
	-var="awsbox_secret_key=${SECRET}" \
	-var="topic_name=${TOPIC}"

ARN_BEFORE="$(terraform output -raw topic_arn)"
[[ -n "$ARN_BEFORE" ]] || fail "empty topic_arn before recreate"

echo "== assert state object + lock table before recreate =="
aws_emu s3api head-object --bucket "$STATE_BUCKET" --key "$STATE_KEY" >/dev/null \
	|| fail "state object missing before recreate"
aws_emu dynamodb describe-table --table-name "$LOCK_TABLE" \
	--query 'Table.TableStatus' --output text | grep -qx ACTIVE \
	|| fail "lock table not ACTIVE before recreate"

echo "== recreate LocalEmu (PERSISTENCE volume kept) =="
"${COMPOSE[@]}" -f "$OVERRIDE" stop localstack >/dev/null
"${COMPOSE[@]}" -f "$OVERRIDE" up -d --force-recreate --no-deps localstack >/dev/null
wait_ready

echo "== assert state object + lock table after recreate =="
aws_emu s3api head-object --bucket "$STATE_BUCKET" --key "$STATE_KEY" >/dev/null \
	|| fail "state object missing after recreate"
aws_emu dynamodb describe-table --table-name "$LOCK_TABLE" \
	--query 'Table.TableStatus' --output text | grep -qx ACTIVE \
	|| fail "lock table not ACTIVE after recreate"

echo "app: plan after recreate (expect no changes)"
set +e
terraform plan -input=false -detailed-exitcode \
	-var="awsbox_endpoint=${EP}" \
	-var="awsbox_access_key=${KEY}" \
	-var="awsbox_secret_key=${SECRET}" \
	-var="topic_name=${TOPIC}" >/dev/null
plan_rc=$?
set -e
[[ "$plan_rc" -eq 0 ]] || fail "plan after recreate expected no changes (detailed-exitcode=${plan_rc})"

ARN_AFTER="$(terraform output -raw topic_arn)"
[[ "$ARN_AFTER" == "$ARN_BEFORE" ]] || fail "topic_arn changed after recreate (${ARN_BEFORE} → ${ARN_AFTER})"

echo "OK: terraform S3+DDB empty plan after LocalEmu recreate (#742) (${STATE_BUCKET} / ${LOCK_TABLE})"
