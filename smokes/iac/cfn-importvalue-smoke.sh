#!/usr/bin/env bash
# Missing Fn::ImportValue must fail with AWS-shaped "No export named … found" (#652).
# Covers: ImportValue nested in Fn::Sub map, and ImportValue as a direct property.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
EXPORT_NAME="awsbox-cfn-noexport-${TS}"
OUT="${TMPDIR:-/tmp}/awsbox-cfn-importvalue-${TS}"
mkdir -p "$OUT"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"

aws() {
	command aws --endpoint-url "$EP" "$@"
}

expect_missing_export() {
	local label="$1"
	local template="$2"
	local stack="awsbox-cfn-imp-${label}-${TS}"
	local log="$OUT/${label}.log"
	local rc=0

	echo "==> ${label}: deploy must fail with No export named ${EXPORT_NAME} found"
	set +e
	aws cloudformation deploy \
		--template-file "$template" \
		--stack-name "$stack" \
		--no-fail-on-empty-changeset >"$log" 2>&1
	rc=$?
	set -e

	aws cloudformation delete-stack --stack-name "$stack" >/dev/null 2>&1 || true

	if [[ "$rc" -eq 0 ]]; then
		echo "error: ${label} deploy succeeded (must fail)" >&2
		cat "$log" >&2
		return 1
	fi
	if ! grep -q "No export named ${EXPORT_NAME} found" "$log"; then
		echo "error: ${label} missing AWS-shaped export error" >&2
		cat "$log" >&2
		return 1
	fi
	if grep -qE 'Unresolved resource dependencies|Missing required parameter' "$log"; then
		echo "error: ${label} still shows misleading LocalEmu error" >&2
		cat "$log" >&2
		return 1
	fi
	echo "ok   ${label}"
}

SUB_TMPL="$OUT/sub.json"
DIRECT_TMPL="$OUT/direct.json"

cat >"$SUB_TMPL" <<EOF
{"Resources":{"P":{"Type":"AWS::SSM::Parameter","Properties":{"Type":"String",
  "Value":{"Fn::Sub":["\${X}/y",{"X":{"Fn::ImportValue":"${EXPORT_NAME}"}}]}}}}}
EOF

cat >"$DIRECT_TMPL" <<EOF
{"Resources":{"P":{"Type":"AWS::SSM::Parameter","Properties":{"Type":"String",
  "Value":{"Fn::ImportValue":"${EXPORT_NAME}"}}}}}
EOF

expect_missing_export "sub" "$SUB_TMPL"
expect_missing_export "direct" "$DIRECT_TMPL"

echo "OK: cfn missing ImportValue errors (#652)"
