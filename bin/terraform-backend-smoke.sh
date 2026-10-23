#!/usr/bin/env bash
# Opt-in: bootstrap S3 state + DynamoDB lock on LocalEmu, apply app workspace,
# assert second plan is no-change. Aborts if a real-AWS STS canary succeeds.
#
#   AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./bin/terraform-backend-smoke.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BOOT="$ROOT/examples/terraform/awsbox-backend/bootstrap"
APP="$ROOT/examples/terraform/awsbox-backend/app"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

if [[ "${AWSBOX_TERRAFORM_BACKEND_SMOKE:-}" != "1" ]]; then
	echo "refusing: set AWSBOX_TERRAFORM_BACKEND_SMOKE=1 to opt in" >&2
	echo "see docs/terraform-awsbox.md" >&2
	exit 2
fi

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
REGION="${AWSBOX_REGION:-us-east-1}"
SUFFIX="$(date +%s)-$$"
STATE_BUCKET="awsbox-tf-state-${SUFFIX}"
LOCK_TABLE="awsbox-tf-locks-${SUFFIX}"
TOPIC="awsbox-tf-topic-${SUFFIX}"
WORKDIR="${TMPDIR:-/tmp}/awsbox-tf-backend-smoke-$$"
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
	rm -rf "$WORKDIR"
}
trap cleanup EXIT

command -v terraform >/dev/null || fail "terraform is required"
command -v aws >/dev/null || fail "aws cli is required"
command -v python3 >/dev/null || fail "python3 is required"

# Endpoint must be loopback / local — never a real AWS hostname.
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

# Canary: STS with no local endpoint. Success ⇒ real AWS reachable with these
# (or ambient) credentials — abort before any Terraform apply.
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
# Keep AWS_ENDPOINT_URL unset for terraform; providers.tf / backend set endpoints.
unset AWS_ENDPOINT_URL || true

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
	AWSBOX_BUCKET="$STATE_BUCKET" AWSBOX_LOCK="$LOCK_TABLE" \
	python3 - <<'PY' >"$APP/backend_override.tf"
import os
ep = os.environ["AWSBOX_EP"]
print(f'''terraform {{
  backend "s3" {{
    bucket         = "{os.environ["AWSBOX_BUCKET"]}"
    key            = "awsbox-backend/app.tfstate"
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

echo "app: apply + no-change plan"
cd "$APP"
terraform init -input=false -reconfigure >/dev/null
terraform apply -input=false -auto-approve \
	-var="awsbox_endpoint=${EP}" \
	-var="awsbox_access_key=${KEY}" \
	-var="awsbox_secret_key=${SECRET}" \
	-var="topic_name=${TOPIC}"

set +e
terraform plan -input=false -detailed-exitcode \
	-var="awsbox_endpoint=${EP}" \
	-var="awsbox_access_key=${KEY}" \
	-var="awsbox_secret_key=${SECRET}" \
	-var="topic_name=${TOPIC}" >/dev/null
plan_rc=$?
set -e
[[ "$plan_rc" -eq 0 ]] || fail "second plan expected no changes (detailed-exitcode=${plan_rc})"

ARN="$(terraform output -raw topic_arn)"
[[ -n "$ARN" ]] || fail "empty topic_arn"

echo "OK: terraform backend smoke (${STATE_BUCKET} / ${LOCK_TABLE} / ${ARN})"
