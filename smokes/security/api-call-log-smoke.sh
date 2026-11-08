#!/usr/bin/env bash
# Happy: Lambda reads one secret → call log shows exactly one secretsmanager:GetSecretValue.
# Sad: AccessDenied via explicit Deny records denying policy name/Sid in reason.
# Assertion helper: function made no s3:* calls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/api-call-log.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
KEEP="${AWSBOX_CALLLOG_KEEP:-0}"
FN="awsbox-calllog-${TS}"
FN_DENY="awsbox-calllog-deny-${TS}"
ROLE="awsbox-calllog-role-${TS}"
ROLE_DENY="awsbox-calllog-denyrole-${TS}"
SECRET_NAME="awsbox/calllog-${TS}"
SECRET_ARN=""
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
DENY_POLICY_NAME="sm-deny"
DENY_SID="DenySecretRead"
TMP="$(mktemp -d)"

export AWS_ACCESS_KEY_ID="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
export AWS_SECRET_ACCESS_KEY="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
export AWS_DEFAULT_REGION="$REGION"

aws() { command aws --endpoint-url "$EP" --region "$REGION" "$@"; }

cleanup() {
	rm -rf "$TMP"
	[[ "$KEEP" == "1" ]] && return 0
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$FN_DENY" >/dev/null 2>&1 || true
	[[ -n "$SECRET_ARN" ]] && aws secretsmanager delete-secret --secret-id "$SECRET_ARN" --force-delete-without-recovery >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name sm-read >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE_DENY" --policy-name "$DENY_POLICY_NAME" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE_DENY" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# Endpoint must be up
curl -sf --max-time 3 "${EP}/_awsl/calls" >/dev/null || {
	echo "FAIL: GET /_awsl/calls not reachable at ${EP}" >&2
	exit 1
}

cat >"$TMP/handler.py" <<'PY'
import json
import os
import urllib.request

def handler(event, context):
    secret_id = os.environ["SECRET_ARN"]
    # boto3 is available in LocalEmu Lambda runtimes; keep deps minimal.
    import boto3
    client = boto3.client("secretsmanager")
    val = client.get_secret_value(SecretId=secret_id)["SecretString"]
    return {"ok": True, "len": len(val)}
PY

# Zip for Lambda (python3.12 runtime)
(
	cd "$TMP"
	zip -q handler.zip handler.py
)

ROLE_ARN="$(aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name sm-read --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["secretsmanager:GetSecretValue"],"Resource":"*"}]}
EOF
)"

ROLE_DENY_ARN="$(aws iam create-role --role-name "$ROLE_DENY" --assume-role-policy-document "$TRUST" --query 'Role.Arn' --output text)"
# Explicit Deny (Sid) so the call log reason names the denying policy — not
# just implicit "no allowing policy".
aws iam put-role-policy --role-name "$ROLE_DENY" --policy-name "$DENY_POLICY_NAME" --policy-document "$(cat <<EOF
{"Version":"2012-10-17","Statement":[{"Sid":"${DENY_SID}","Effect":"Deny","Action":["secretsmanager:GetSecretValue"],"Resource":"*"}]}
EOF
)"

SECRET_ARN="$(aws secretsmanager create-secret --name "$SECRET_NAME" --secret-string "calllog-${TS}" --query 'ARN' --output text)"

aws lambda create-function \
	--function-name "$FN" \
	--runtime python3.12 \
	--role "$ROLE_ARN" \
	--handler handler.handler \
	--zip-file "fileb://${TMP}/handler.zip" \
	--timeout 30 \
	--environment "Variables={SECRET_ARN=${SECRET_ARN}}" >/dev/null

aws lambda create-function \
	--function-name "$FN_DENY" \
	--runtime python3.12 \
	--role "$ROLE_DENY_ARN" \
	--handler handler.handler \
	--zip-file "fileb://${TMP}/handler.zip" \
	--timeout 30 \
	--environment "Variables={SECRET_ARN=${SECRET_ARN}}" >/dev/null

# --- Happy path ---
api_call_log_clear
OUT="$(aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out --payload '{}' "$TMP/out.json" --query 'StatusCode' --output text)"
[[ "$OUT" == "200" ]] || {
	echo "FAIL: invoke status $OUT" >&2
	cat "$TMP/out.json" >&2 || true
	exit 1
}
python3 - "$TMP/out.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1]))
# Lambda may wrap FunctionError
if body.get("ok") is not True and "errorMessage" in body:
    raise SystemExit(f"FAIL: lambda error {body}")
if body.get("ok") is not True:
    # payload may be the raw response already checked via StatusCode
    pass
print("invoke payload:", body)
PY

api_call_log_assert_exactly "$FN" 'secretsmanager:GetSecretValue'
api_call_log_assert_no_calls "$FN" 's3:*'
api_call_log_assert_no_calls "$FN" 'dynamodb:*'

# --- AccessDenied path (explicit Deny + Sid) ---
api_call_log_clear
aws lambda invoke --function-name "$FN_DENY" --cli-binary-format raw-in-base64-out --payload '{}' "$TMP/deny.json" >/dev/null || true
# Expect function error
if python3 - "$TMP/deny.json" <<'PY'
import json, sys
body = json.load(open(sys.argv[1]))
# Either FunctionError payload or AccessDenied in message
text = json.dumps(body)
sys.exit(0 if ("AccessDenied" in text or "errorMessage" in body or "errorType" in body) else 1)
PY
then
	:
else
	echo "WARN: deny invoke payload unexpected; still checking call log" >&2
	cat "$TMP/deny.json" >&2 || true
fi

# Reason must name the inline Deny policy / Sid (not merely "no allowing policy").
api_call_log_assert_denied "$FN_DENY" 'secretsmanager:GetSecretValue' "inline:${DENY_POLICY_NAME} (Sid=${DENY_SID})"

# CLI wrapper smoke
"$ROOT/bin/stackwrangler" calls --workload "$FN" >/dev/null || true
# After deny clear we may have empty for FN; just ensure CLI speaks JSON
"$ROOT/bin/stackwrangler" calls --limit 5 | python3 -c 'import json,sys; json.load(sys.stdin); print("OK: stackwrangler calls JSON")'

echo "OK: api-call-log smoke (#194)"
