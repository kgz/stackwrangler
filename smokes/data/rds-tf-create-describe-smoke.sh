#!/usr/bin/env bash
# #718: CreateDBInstance then Describe must stay fast (no multi-minute hang).
# Bounds wall clock and per-Describe latency so a TF-style waiter stall fails
# the smoke instead of sitting for tens of minutes.
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
DB_ID="sw-rds-tf-stall-${TS}"
PG_NAME="sw-rds-tf-stall-pg-${TS}"
KEEP="${STACKWRANGLER_RDS_TF_STALL_KEEP:-0}"
# Overall budget after Create returns (TF itself waits ≥~80s by design; we use CLI).
OVERALL_S="${STACKWRANGLER_RDS_TF_STALL_TIMEOUT_S:-90}"
# Single Describe must not block (completion-only logs hid ~55m hangs).
DESCRIBE_S="${STACKWRANGLER_RDS_TF_STALL_DESCRIBE_S:-5}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWS_MAX_ATTEMPTS=1
export AWS_PAGER=""

aws() {
	# Default read budget for create/delete; Describe uses a tighter wrap below.
	command aws --endpoint-url "$EP" --cli-read-timeout 120 --cli-connect-timeout 5 "$@"
}

aws_describe() {
	command aws --endpoint-url "$EP" --cli-read-timeout "$DESCRIBE_S" --cli-connect-timeout 5 "$@"
}

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws rds delete-db-instance --db-instance-identifier "$DB_ID" --skip-final-snapshot >/dev/null 2>&1 || true
	aws rds delete-db-parameter-group --db-parameter-group-name "$PG_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> parameter group + CreateDBInstance (mysql 8.0.37)"
aws rds create-db-parameter-group \
	--db-parameter-group-name "$PG_NAME" \
	--db-parameter-group-family mysql8.0 \
	--description "sw #718 tf-stall smoke" >/dev/null

aws rds modify-db-parameter-group \
	--db-parameter-group-name "$PG_NAME" \
	--parameters \
	"ParameterName=character_set_server,ParameterValue=utf8mb4,ApplyMethod=immediate" \
	"ParameterName=max_connections,ParameterValue=100,ApplyMethod=pending-reboot" >/dev/null

CREATE_START="$(date +%s)"
CREATE_JSON="$(aws rds create-db-instance \
	--db-instance-identifier "$DB_ID" \
	--db-instance-class db.t3.micro \
	--engine mysql \
	--engine-version 8.0.37 \
	--master-username admin \
	--master-user-password 'ReproOnlyPassword1' \
	--allocated-storage 20 \
	--db-parameter-group-name "$PG_NAME" \
	--output json)"
CREATE_END="$(date +%s)"
CREATE_WALL=$((CREATE_END - CREATE_START))
echo "OK: CreateDBInstance wall=${CREATE_WALL}s"

CREATE_STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["DBInstance"]["DBInstanceStatus"])' <<<"$CREATE_JSON")"
CREATE_RES="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["DBInstance"].get("DbiResourceId",""))' <<<"$CREATE_JSON")"
[[ -n "$CREATE_RES" ]] || fail "Create missing DbiResourceId"
[[ "$CREATE_RES" == db-* ]] || fail "DbiResourceId shape: $CREATE_RES"

echo "==> poll DescribeDBInstances (overall≤${OVERALL_S}s, each≤${DESCRIBE_S}s)"
DEADLINE=$((CREATE_END + OVERALL_S))
AVAILABLE_HITS=0
MAX_DESCRIBE_S=0
while true; do
	NOW="$(date +%s)"
	if (( NOW > DEADLINE )); then
		fail "not available within ${OVERALL_S}s after Create (max_describe_s=${MAX_DESCRIBE_S})"
	fi
	T0="$(date +%s)"
	if ! DESC_JSON="$(aws_describe rds describe-db-instances --db-instance-identifier "$DB_ID" --output json 2>/tmp/sw-rds-tf-stall-desc.err)"; then
		err="$(cat /tmp/sw-rds-tf-stall-desc.err 2>/dev/null || true)"
		if echo "$err" | grep -qiE 'timeout|timed out|Read timeout'; then
			fail "DescribeDBInstances exceeded ${DESCRIBE_S}s read timeout (hung request)"
		fi
		fail "DescribeDBInstances failed: $err"
	fi
	T1="$(date +%s)"
	SECS=$((T1 - T0))
	if (( SECS > MAX_DESCRIBE_S )); then
		MAX_DESCRIBE_S=$SECS
	fi
	if (( SECS > DESCRIBE_S )); then
		fail "DescribeDBInstances took ${SECS}s (>${DESCRIBE_S}s)"
	fi
	STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["DBInstances"][0]["DBInstanceStatus"])' <<<"$DESC_JSON")"
	RES="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["DBInstances"][0].get("DbiResourceId",""))' <<<"$DESC_JSON")"
	[[ "$RES" == "$CREATE_RES" ]] || fail "DbiResourceId changed create=$CREATE_RES describe=$RES"
	if [[ "$STATUS" == "available" ]]; then
		AVAILABLE_HITS=$((AVAILABLE_HITS + 1))
		# Mimic TF ContinuousTargetOccurence=3 with short polls.
		if (( AVAILABLE_HITS >= 3 )); then
			break
		fi
	else
		AVAILABLE_HITS=0
		echo "  status=$STATUS (create_status=$CREATE_STATUS)"
	fi
	sleep 1
done

WALL=$(( $(date +%s) - CREATE_END ))
echo "OK: available x3 after Create in ${WALL}s (max_describe_s=${MAX_DESCRIBE_S}, create_wall=${CREATE_WALL}s)"
(( WALL <= OVERALL_S )) || fail "post-create wait ${WALL}s > ${OVERALL_S}s"

# Optional: terraform apply with hard timeout (skip if no terraform).
if command -v terraform >/dev/null && command -v timeout >/dev/null; then
	TFDIR="$(mktemp -d /tmp/sw-rds-tf-stall.XXXXXX)"
	cat >"$TFDIR/main.tf" <<EOF
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
    }
  }
}
provider "aws" {
  region                      = "$REGION"
  access_key                  = "$KEY"
  secret_key                  = "$SECRET"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true
  endpoints {
    rds = "$EP"
  }
}
resource "aws_db_parameter_group" "p" {
  name   = "${PG_NAME}-tf"
  family = "mysql8.0"
  parameter {
    name         = "character_set_server"
    value        = "utf8mb4"
    apply_method = "immediate"
  }
}
resource "aws_db_instance" "db" {
  identifier           = "${DB_ID}-tf"
  engine               = "mysql"
  engine_version       = "8.0.37"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20
  username             = "admin"
  password             = "ReproOnlyPassword1"
  parameter_group_name = aws_db_parameter_group.p.name
  skip_final_snapshot  = true
  apply_immediately    = true
}
EOF
	echo "==> terraform apply (timeout ${OVERALL_S}s — fails on multi-minute stall)"
	(
		cd "$TFDIR"
		terraform init -input=false -no-color >/tmp/sw-rds-tf-stall-tf-init.log
		# TF waits ≥1m by design after Create; allow OVERALL_S + create budget.
		TF_BUDGET=$((OVERALL_S + 120))
		if ! timeout "${TF_BUDGET}s" terraform apply -input=false -auto-approve -no-color \
			>/tmp/sw-rds-tf-stall-tf-apply.log 2>&1; then
			tail -40 /tmp/sw-rds-tf-stall-tf-apply.log >&2 || true
			rm -rf "$TFDIR"
			fail "terraform apply hit ${TF_BUDGET}s timeout (likely post-Create stall)"
		fi
		timeout 60s terraform destroy -input=false -auto-approve -no-color >/dev/null 2>&1 || true
	)
	rm -rf "$TFDIR"
	echo "OK: terraform apply finished within budget"
else
	echo "SKIP: terraform/timeout not installed — CLI bound already covers hang"
fi

echo "PASS: rds-tf-create-describe-smoke"
