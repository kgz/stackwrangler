#!/usr/bin/env bash
# Isolated Prowler run against LocalEmu. Fails if distinct failing API calls
# rise above testdata/prowler/failing-api-baseline.txt (#196).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

REGION="${AWSBOX_REGION:-us-east-1}"
ACCESS_KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET_KEY="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
# Account-id virtual host form needs a wildcard DNS host (not 127.0.0.1).
ENDPOINT="${AWSBOX_PROWLER_ENDPOINT:-http://localhost.localstack.cloud:4566}"
BASELINE_FILE="${AWSBOX_PROWLER_BASELINE:-$ROOT/testdata/prowler/failing-api-baseline.txt}"
VENV_DIR="${AWSBOX_PROWLER_VENV:-$ROOT/.venv-prowler}"
PROWLER_VERSION="${AWSBOX_PROWLER_VERSION:-5.45.0}"
WORKDIR="${TMPDIR:-/tmp}/awsbox-prowler-$$"
mkdir -p "$WORKDIR/out"
trap 'rm -rf "$WORKDIR"' EXIT

ensure_prowler() {
	if [[ -x "$VENV_DIR/bin/prowler" ]]; then
		return 0
	fi
	echo "installing prowler==${PROWLER_VERSION} into ${VENV_DIR}" >&2
	python3 -m venv "$VENV_DIR"
	"$VENV_DIR/bin/pip" install -q "prowler==${PROWLER_VERSION}"
}

write_isolated_aws() {
	cat >"$WORKDIR/credentials" <<EOF
[default]
aws_access_key_id = ${ACCESS_KEY}
aws_secret_access_key = ${SECRET_KEY}
EOF
	cat >"$WORKDIR/config" <<EOF
[default]
region = ${REGION}
output = json
EOF
}

# Extract distinct failing API operations from Prowler ERROR logs.
parse_failing_apis() {
	python3 - <<'PY' "$1"
import re, sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="replace")
found: set[str] = set()

# botocore: "An error occurred (Code) when calling the Op operation"
for m in re.finditer(
    r"when calling the ([A-Za-z0-9]+) operation", text, re.I
):
    found.add(m.group(1))

# "exception while calling s3control.GetPublicAccessBlock"
for m in re.finditer(
    r"exception while calling\s+([a-z0-9_-]+)\.([A-Za-z0-9]+)", text, re.I
):
    found.add(f"{m.group(1)}.{m.group(2)}")

# Unresolved / bad hosts (S3 Control classic failure mode)
for m in re.finditer(r"Failed to resolve ['\"]([^'\"]+)['\"]", text, re.I):
    found.add(f"DNS:{m.group(1)}")
for m in re.finditer(
    r"Could not connect to the endpoint URL:\s*[\"']([^\"']+)[\"']", text, re.I
):
    found.add(f"ENDPOINT:{m.group(1)}")

# LocalEmu / moto not implemented
for m in re.finditer(
    r"The ([A-Za-z0-9_]+) action has not been implemented", text
):
    found.add(m.group(1))

# Ignore expected empty-account Organizations shape (valid AWS error)
# and snake_case duplicates of CamelCase ops from moto messages.
ignore = {"DescribeOrganization"}
found = {
    t
    for t in found
    if t not in ignore and not (t.islower() or "_" in t)
}

print("\n".join(sorted(found)))
PY
}

ensure_prowler
write_isolated_aws

LOG_FILE="$WORKDIR/prowler.log"
set +e
# env -i: no AWS_* from the operator shell; only what we pass.
env -i \
	HOME="$WORKDIR" \
	PATH="/usr/bin:/bin:$VENV_DIR/bin" \
	TERM="${TERM:-dumb}" \
	LANG="${LANG:-C.UTF-8}" \
	AWS_ACCESS_KEY_ID="$ACCESS_KEY" \
	AWS_SECRET_ACCESS_KEY="$SECRET_KEY" \
	AWS_DEFAULT_REGION="$REGION" \
	AWS_REGION="$REGION" \
	AWS_ENDPOINT_URL="$ENDPOINT" \
	AWS_SHARED_CREDENTIALS_FILE="$WORKDIR/credentials" \
	AWS_CONFIG_FILE="$WORKDIR/config" \
	AWS_EC2_METADATA_DISABLED=true \
	"$VENV_DIR/bin/prowler" aws \
	--no-banner \
	--log-level ERROR \
	-f "$REGION" \
	--scan-unused-services \
	--service s3 iam ec2 rds ssm cloudwatch cloudtrail organizations backup \
	awslambda apigateway batch autoscaling \
	--output-directory "$WORKDIR/out" \
	--output-formats csv \
	--ignore-exit-code-3 \
	>"$LOG_FILE" 2>&1
PROWLER_RC=$?
set -e

if [[ "$PROWLER_RC" -ne 0 ]]; then
	echo "error: prowler exited ${PROWLER_RC} (expected 0 with --ignore-exit-code-3)" >&2
	tail -n 40 "$LOG_FILE" >&2 || true
	exit 1
fi

FAILING_FILE="$WORKDIR/failing.txt"
parse_failing_apis "$LOG_FILE" | sed '/^$/d' >"$FAILING_FILE"
COUNT="$(wc -l <"$FAILING_FILE" | tr -d ' ')"

echo "prowler exit=${PROWLER_RC} distinct_failing_apis=${COUNT} endpoint=${ENDPOINT}"
if [[ "$COUNT" -gt 0 ]]; then
	echo "--- failing API tokens ---"
	cat "$FAILING_FILE"
fi

if [[ ! -f "$BASELINE_FILE" ]]; then
	echo "error: missing baseline ${BASELINE_FILE}" >&2
	exit 1
fi

BASELINE_COUNT="$(grep -cve '^[[:space:]]*#' -e '^[[:space:]]*$' "$BASELINE_FILE" || true)"
if [[ "$COUNT" -gt "$BASELINE_COUNT" ]]; then
	echo "error: failing API count ${COUNT} > baseline ${BASELINE_COUNT} (${BASELINE_FILE})" >&2
	echo "new vs baseline:" >&2
	comm -13 <(grep -ve '^#' -e '^$' "$BASELINE_FILE" | sort -u) <(sort -u "$FAILING_FILE") >&2 || true
	exit 1
fi

if grep -qE 'DNS:.*127\.0\.0\.1|ENDPOINT:.*[0-9]+\.127\.0\.0\.1' "$FAILING_FILE"; then
	echo "error: S3 Control still using unresolved <account>.127.0.0.1 host" >&2
	exit 1
fi

# Spot-check: S3 Control public access must work on the smoke endpoint
export AWS_ACCESS_KEY_ID="$ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$SECRET_KEY" AWS_DEFAULT_REGION="$REGION" AWS_EC2_METADATA_DISABLED=true
aws --endpoint-url "$ENDPOINT" s3control get-public-access-block --account-id 000000000000 >/dev/null
aws --endpoint-url "$ENDPOINT" s3control list-access-points --account-id 000000000000 >/dev/null
aws --endpoint-url "$ENDPOINT" s3control list-multi-region-access-points --account-id 000000000000 >/dev/null

echo "OK: prowler-smoke (failing=${COUNT} ≤ baseline=${BASELINE_COUNT})"
