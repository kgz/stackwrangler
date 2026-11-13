#!/usr/bin/env bash
# RDS parameter groups: Describe returns Source=user so Terraform converges (#710).
# CLI modify/describe + aws_db_parameter_group apply → empty second plan.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${STACKWRANGLER_IAM_ENDPOINT:-${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
PG_NAME="sw-rds-pg-${TS}"
CLUSTER_PG_NAME="sw-rds-cpg-${TS}"
KEEP="${STACKWRANGLER_RDS_PG_KEEP:-${AWSBOX_RDS_PG_KEEP:-0}}"
TFDIR=""

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	if [[ -n "$TFDIR" && -d "$TFDIR" ]]; then
		if [[ -d "$TFDIR/.terraform" ]]; then
			(
				cd "$TFDIR"
				terraform destroy -input=false -auto-approve \
					-var "awsbox_endpoint=$EP" \
					-var "awsbox_access_key=$KEY" \
					-var "awsbox_secret_key=$SECRET" \
					-var "pg_name=${PG_NAME}-tf" \
					>/dev/null 2>&1 || true
			)
		fi
		rm -rf "$TFDIR"
	fi
	aws rds delete-db-parameter-group --db-parameter-group-name "$PG_NAME" >/dev/null 2>&1 || true
	aws rds delete-db-cluster-parameter-group --db-cluster-parameter-group-name "$CLUSTER_PG_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> CLI: create + modify DB parameter group"
aws rds create-db-parameter-group \
	--db-parameter-group-name "$PG_NAME" \
	--db-parameter-group-family mysql8.0 \
	--description "sw rds pg smoke" >/dev/null

aws rds modify-db-parameter-group \
	--db-parameter-group-name "$PG_NAME" \
	--parameters \
	"ParameterName=sql_mode,ParameterValue=,ApplyMethod=pending-reboot" \
	"ParameterName=max_connections,ParameterValue=50,ApplyMethod=immediate" >/dev/null

PARAMS_JSON="$(aws rds describe-db-parameters --db-parameter-group-name "$PG_NAME" --source user --output json)"
python3 - "$PARAMS_JSON" <<'PY' || fail "describe-db-parameters --source user shape"
import json, sys
params = {p["ParameterName"]: p for p in json.loads(sys.argv[1])["Parameters"]}
for name in ("sql_mode", "max_connections"):
    if name not in params:
        raise SystemExit(f"missing {name}")
    p = params[name]
    if p.get("Source") != "user":
        raise SystemExit(f"{name} Source={p.get('Source')!r} want user")
    if "ApplyMethod" not in p:
        raise SystemExit(f"{name} missing ApplyMethod")
    if "IsModifiable" not in p:
        raise SystemExit(f"{name} missing IsModifiable")
    if "ApplyType" not in p:
        raise SystemExit(f"{name} missing ApplyType")
print("OK: CLI user parameters include Source/ApplyType")
PY

EMPTY_ENGINE="$(aws rds describe-db-parameters --db-parameter-group-name "$PG_NAME" --source engine-default --query 'length(Parameters)' --output text)"
[[ "$EMPTY_ENGINE" == "0" ]] || fail "engine-default filter should be empty (got ${EMPTY_ENGINE})"

echo "==> CLI: cluster parameter group Source=user"
aws rds create-db-cluster-parameter-group \
	--db-cluster-parameter-group-name "$CLUSTER_PG_NAME" \
	--db-parameter-group-family aurora-mysql8.0 \
	--description "sw rds cluster pg smoke" >/dev/null

aws rds modify-db-cluster-parameter-group \
	--db-cluster-parameter-group-name "$CLUSTER_PG_NAME" \
	--parameters "ParameterName=server_audit_logging,ParameterValue=1,ApplyMethod=immediate" >/dev/null

CP_SRC="$(aws rds describe-db-cluster-parameters --db-cluster-parameter-group-name "$CLUSTER_PG_NAME" --source user \
	--query 'Parameters[?ParameterName==`server_audit_logging`].Source' --output text)"
[[ "$CP_SRC" == "user" ]] || fail "cluster param Source=${CP_SRC} want user"

command -v terraform >/dev/null || fail "terraform is required"

TFDIR="$(mktemp -d /tmp/sw-rds-pg-tf.XXXXXX)"
cat >"$TFDIR/main.tf" <<EOF
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}

variable "awsbox_endpoint" { type = string }
variable "awsbox_access_key" { type = string }
variable "awsbox_secret_key" { type = string }
variable "pg_name" { type = string }

provider "aws" {
  region                      = "us-east-1"
  access_key                  = var.awsbox_access_key
  secret_key                  = var.awsbox_secret_key
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    rds = var.awsbox_endpoint
    sts = var.awsbox_endpoint
    iam = var.awsbox_endpoint
  }
}

resource "aws_db_parameter_group" "p" {
  name   = var.pg_name
  family = "mysql8.0"

  parameter {
    name         = "sql_mode"
    value        = ""
    apply_method = "pending-reboot"
  }
}
EOF

echo "==> Terraform: apply aws_db_parameter_group + empty second plan"
(
	cd "$TFDIR"
	terraform init -input=false >/dev/null
	terraform apply -input=false -auto-approve \
		-var "awsbox_endpoint=$EP" \
		-var "awsbox_access_key=$KEY" \
		-var "awsbox_secret_key=$SECRET" \
		-var "pg_name=${PG_NAME}-tf" >/dev/null
	# exit 0 = no changes; 2 = drift
	set +e
	terraform plan -input=false -detailed-exitcode \
		-var "awsbox_endpoint=$EP" \
		-var "awsbox_access_key=$KEY" \
		-var "awsbox_secret_key=$SECRET" \
		-var "pg_name=${PG_NAME}-tf" >/tmp/sw-rds-pg-plan.out 2>&1
	rc=$?
	set -e
	[[ "$rc" -eq 0 ]] || {
		echo "---- terraform plan ----" >&2
		cat /tmp/sw-rds-pg-plan.out >&2
		fail "second terraform plan not empty (exit ${rc})"
	}
)

echo "OK: rds parameter group Source=user + terraform converge (${PG_NAME})"
