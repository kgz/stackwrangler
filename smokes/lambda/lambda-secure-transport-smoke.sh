#!/usr/bin/env bash
# Lambda AWS_ENDPOINT_URL is https + trusted CA so aws:SecureTransport=true
# (#696). Bucket DenyNonSSL must not block a correctly permissioned role.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
TS="$(date +%s)"
FN="awsbox-lambda-st-${TS}"
ROLE="awsbox-lambda-st-${TS}"
BUCKET="awsbox-lambda-st-${TS}"
ZIP="$ROOT/.awsbox/lambda-secure-transport.zip"
OUT="/tmp/awsbox-lambda-st-out.json"
KEEP="${AWSBOX_LAMBDA_ST_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE AWS_SESSION_TOKEN || true

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	[[ "$KEEP" == "1" ]] && { rm -f "$ZIP"; return 0; }
	aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ROLE" --policy-name allow-s3 >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ROLE" >/dev/null 2>&1 || true
	aws s3api delete-bucket-policy --bucket "$BUCKET" >/dev/null 2>&1 || true
	aws s3 rb "s3://${BUCKET}" --force >/dev/null 2>&1 || true
	rm -f "$ZIP" "$OUT"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$ROOT/.awsbox"
python3 - <<'PY' "$ZIP"
import sys, zipfile
path = sys.argv[1]
code = b"""const fs = require("fs");
const { S3Client, GetObjectCommand } = require("@aws-sdk/client-s3");

async function streamToString(stream) {
  const chunks = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks).toString("utf8");
}

exports.handler = async (event) => {
  const endpoint = process.env.AWS_ENDPOINT_URL || "";
  const caBundle = process.env.AWS_CA_BUNDLE || "";
  const nodeCa = process.env.NODE_EXTRA_CA_CERTS || "";
  const sslFile = process.env.SSL_CERT_FILE || "";
  const caMounted = fs.existsSync("/etc/awsbox/certs/ca.crt");
  const bundleMounted = fs.existsSync("/etc/awsbox/certs/ca-bundle.crt");
  const out = {
    endpoint,
    caBundle,
    nodeCa,
    sslFile,
    caMounted,
    bundleMounted,
  };
  if (event && event.mode === "env-only") {
    return out;
  }
  const client = new S3Client({
    region: process.env.AWS_REGION || "us-east-1",
    forcePathStyle: true,
  });
  try {
    const resp = await client.send(new GetObjectCommand({
      Bucket: event.bucket,
      Key: event.key || "obj.txt",
    }));
    out.body = await streamToString(resp.Body);
    out.ok = true;
  } catch (err) {
    out.ok = false;
    out.name = err.name || null;
    out.code = err.Code || err.code || err.$metadata?.httpStatusCode || null;
    out.message = String(err.message || err);
  }
  return out;
};
"""
with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr("index.js", code)
PY

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam create-role --role-name "$ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ROLE_ARN="$(aws iam get-role --role-name "$ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$ROLE" --policy-name allow-s3 --policy-document "$(BUCKET="$BUCKET" python3 -c '
import json, os
b = os.environ["BUCKET"]
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:ListBucket"],
    "Resource": [f"arn:aws:s3:::{b}", f"arn:aws:s3:::{b}/*"],
  }],
}))
')" >/dev/null

aws s3 mb "s3://${BUCKET}" >/dev/null
echo "secure-transport-ok" | aws s3 cp - "s3://${BUCKET}/obj.txt"
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "$(BUCKET="$BUCKET" python3 -c '
import json, os
b = os.environ["BUCKET"]
print(json.dumps({
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyNonSSL",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": [f"arn:aws:s3:::{b}", f"arn:aws:s3:::{b}/*"],
    "Condition": {"Bool": {"aws:SecureTransport": "false"}},
  }],
}))
')" >/dev/null

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
[[ "$state" == "Active" ]] || fail "function never Active (state=${state})"

ENV_PAYLOAD='{"mode":"env-only"}'
aws lambda invoke \
	--function-name "$FN" \
	--payload "$ENV_PAYLOAD" \
	--cli-binary-format raw-in-base64-out \
	"$OUT" >/dev/null
ENV_BODY="$(cat "$OUT")"
echo "EnvPayload=${ENV_BODY}"

echo "$ENV_BODY" | grep -qE '"endpoint"[[:space:]]*:[[:space:]]*"https://localemu\.awsbox:' \
	|| fail "expected https://localemu.awsbox endpoint: $ENV_BODY"
echo "$ENV_BODY" | grep -qE '"caBundle"[[:space:]]*:[[:space:]]*"/etc/awsbox/certs/ca-bundle\.crt"' \
	|| fail "missing AWS_CA_BUNDLE: $ENV_BODY"
echo "$ENV_BODY" | grep -qE '"nodeCa"[[:space:]]*:[[:space:]]*"/etc/awsbox/certs/ca\.crt"' \
	|| fail "missing NODE_EXTRA_CA_CERTS: $ENV_BODY"
echo "$ENV_BODY" | grep -qE '"sslFile"[[:space:]]*:[[:space:]]*"/etc/awsbox/certs/ca-bundle\.crt"' \
	|| fail "missing SSL_CERT_FILE: $ENV_BODY"
echo "$ENV_BODY" | grep -qE '"caMounted"[[:space:]]*:[[:space:]]*true' \
	|| fail "CA not mounted: $ENV_BODY"
echo "$ENV_BODY" | grep -qE '"bundleMounted"[[:space:]]*:[[:space:]]*true' \
	|| fail "CA bundle not mounted: $ENV_BODY"

GET_PAYLOAD="$(BUCKET="$BUCKET" python3 -c 'import json,os; print(json.dumps({"bucket":os.environ["BUCKET"],"key":"obj.txt"}))')"
aws lambda invoke \
	--function-name "$FN" \
	--payload "$GET_PAYLOAD" \
	--cli-binary-format raw-in-base64-out \
	"$OUT" >/dev/null
GOT="$(cat "$OUT")"
echo "GetPayload=${GOT}"

echo "$GOT" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true' \
	|| fail "Lambda GetObject failed (SecureTransport?): $GOT"
echo "$GOT" | grep -q 'secure-transport-ok' \
	|| fail "unexpected object body: $GOT"

echo "OK: lambda secure-transport (#696)"
