#!/usr/bin/env bash
# Sad path: Lambda execution role without s3:PutObject → AccessDenied on put.
# Happy counterpart remains ./bin/lambda-smoke.sh / cfn-smoke (role with s3).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${AWSBOX_REGION:-us-east-1}"
KEY="${AWSBOX_ACCESS_KEY:-awsbox}"
SECRET="${AWSBOX_SECRET_KEY:-awsboxawsbox}"
TS="$(date +%s)"
FN="awsbox-authz-deny-${TS}"
ROLE="awsbox-lambda-noperm-${TS}"
BUCKET="awsbox-authz-${TS}"
ZIP="$ROOT/.awsbox/lambda-authz-deny.zip"
OUT="/tmp/awsbox-lambda-authz-out.json"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	rm -f "$ZIP"
}
trap cleanup EXIT

mkdir -p "$ROOT/.awsbox"
python3 - <<'PY' "$ZIP"
import sys, zipfile
path = sys.argv[1]
code = b"""const { S3Client, PutObjectCommand } = require("@aws-sdk/client-s3");
exports.handler = async (event) => {
  const bucket = event.bucket;
  // LocalEmu injects endpoint/creds for the execution role; do not use 127.0.0.1.
  const client = new S3Client({
    region: process.env.AWS_REGION || "us-east-1",
    forcePathStyle: true,
  });
  try {
    await client.send(new PutObjectCommand({
      Bucket: bucket,
      Key: "authz-probe.txt",
      Body: "should-deny",
    }));
    return { ok: true, wrote: true };
  } catch (err) {
    return {
      ok: false,
      name: err.name || null,
      code: err.Code || err.code || err.$metadata?.httpStatusCode || null,
      message: String(err.message || err),
    };
  }
};
"""
with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

# Role: can be assumed by Lambda, but NO S3 permissions.
TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"

aws s3 mb "s3://${BUCKET}"

aws lambda create-function \
	--function-name "$FN" \
	--runtime nodejs18.x \
	--role "$ROLE_ARN" \
	--handler index.handler \
	--zip-file "fileb://${ZIP}" \
	--timeout 30 >/dev/null

echo "waiting for ${FN} Active…"
state=""
for _ in $(seq 1 60); do
	state="$(aws lambda get-function --function-name "$FN" \
		--query 'Configuration.State' --output text 2>/dev/null || echo Pending)"
	[[ "$state" == "Active" ]] && break
	sleep 2
done
[[ "$state" == "Active" ]] || {
	echo "FAIL: function never Active (state=${state})" >&2
	exit 1
}

PAYLOAD="$(python3 -c "import json; print(json.dumps({\"bucket\":\"${BUCKET}\"}))")"
aws lambda invoke \
	--function-name "$FN" \
	--payload "$PAYLOAD" \
	--cli-binary-format raw-in-base64-out \
	"$OUT" >/dev/null

BODY="$(cat "$OUT")"
echo "Payload=${BODY}"

# Must NOT have succeeded the put.
if echo "$BODY" | grep -qE '"wrote"[[:space:]]*:[[:space:]]*true|"ok"[[:space:]]*:[[:space:]]*true'; then
	# ok:true with wrote is failure of the sad path
	if echo "$BODY" | grep -qE '"wrote"[[:space:]]*:[[:space:]]*true'; then
		echo "FAIL: put succeeded; expected AccessDenied under empty role" >&2
		exit 1
	fi
fi

if ! echo "$BODY" | grep -qiE 'AccessDenied|not authorized|ExplicitDeny|Unauthorized|Forbidden|Access Denied'; then
	echo "FAIL: expected AccessDenied-class error in payload:" >&2
	echo "$BODY" >&2
	exit 1
fi

echo "OK: Lambda role without s3:PutObject → AccessDenied (${FN})"
