#!/usr/bin/env bash
# Deliberate Serverless v3 failure (#330): deploy with a missing ${ssm:…}
# path must not report "Service deployed". Exit 0 only when that failure is observed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EX="$ROOT/examples/serverless-v3-rest"
# shellcheck disable=SC1091
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a
# shellcheck disable=SC1091
source "$ROOT/smokes/lib/local-emu-env.sh"

EP="${AWSBOX_IAM_ENDPOINT:-http://127.0.0.1:4566}"
KEY="${STACKWRANGLER_ACCESS_KEY:-${AWSBOX_ACCESS_KEY:-stackwrangler}}"
SECRET="${STACKWRANGLER_SECRET_KEY:-${AWSBOX_SECRET_KEY:-stackwranglerstackwrangler}}"
REGION="${STACKWRANGLER_REGION:-${AWSBOX_REGION:-us-east-1}}"
TS="$(date +%s)"
STAGE="local"
DEPLOY_BUCKET="awsbox-sls-sad-deploy-${TS}"
SUFFIX="sad-${TS}"
SERVICE="awsbox-rest-sad-${TS}"
STACK="${SERVICE}-${STAGE}"
KEEP="${AWSBOX_SLS_V3_KEEP:-0}"
OUT="$ROOT/.awsbox/serverless-v3-sad-${TS}"
SLS_TIMEOUT_SECS="${AWSBOX_SLS_TIMEOUT_SECS:-120}"
BAD_SSM="/demo/rest/${SUFFIX}/app-name"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export AWS_ENDPOINT_URL="$EP"
export AWSBOX_SLSE_DEPLOY_BUCKET="$DEPLOY_BUCKET"
export AWSBOX_SLSE_SUFFIX="$SUFFIX"
export AWSBOX_SLSE_SERVICE="$SERVICE"
export CI=1
export SLS_TELEMETRY_DISABLED=1
export SLS_INTERACTIVE_SETUP_ENABLE=0

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

cleanup() {
	if [[ "$KEEP" == "1" ]]; then
		return 0
	fi
	(
		cd "$EX"
		timeout --signal=KILL 90 stdbuf -oL -eL \
			npx serverless remove --stage "$STAGE" --verbose
	) >"$OUT/remove-cleanup.log" 2>&1 || true
	aws cloudformation delete-stack --stack-name "$STACK" >/dev/null 2>&1 || true
	aws s3 rb "s3://${DEPLOY_BUCKET}" --force >/dev/null 2>&1 || true
	# Never created the param in the happy path; delete if a prior run left one.
	aws ssm delete-parameter --name "$BAD_SSM" >/dev/null 2>&1 || true
	[[ "$KEEP" == "1" ]] || rm -rf "$OUT"
}
trap cleanup EXIT

mkdir -p "$OUT"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
	echo "error: LocalEmu not reachable at ${EP} (./bin/awsbox up)" >&2
	exit 1
fi

if [[ ! -d "$EX/node_modules/serverless" ]]; then
	(cd "$EX" && npm install --no-fund --no-audit)
fi

# Deploy bucket exists so the failure is the missing SSM path, not S3.
aws s3 mb "s3://${DEPLOY_BUCKET}" >/dev/null
# Intentionally do NOT put-parameter for ${ssm:/demo/rest/${SUFFIX}/app-name}.
if aws ssm get-parameter --name "$BAD_SSM" >/dev/null 2>&1; then
	echo "error: ${BAD_SSM} already exists — cannot assert missing-ssm sad path" >&2
	exit 1
fi

echo "==> sad: serverless deploy with missing SSM ${BAD_SSM}"
LOG="$OUT/deploy-missing-ssm.log"
set +e
(
	cd "$EX"
	timeout --signal=KILL "${SLS_TIMEOUT_SECS}" \
		stdbuf -oL -eL \
		npx serverless deploy --stage "$STAGE" --verbose
) >"$LOG" 2>&1
rc=$?
set -e
sed 's/\x1b\[[0-9;]*[A-Za-z]//g' "$LOG" | tr -d '\r' | tee "$OUT/deploy-missing-ssm.clean.log" || cat "$LOG"

if grep -qiE 'Service deployed|Stack create finished' "$LOG"; then
	echo "error: missing-SSM deploy looked successful (must not pass)" >&2
	exit 1
fi
if grep -qiE 'CREATE_COMPLETE' "$LOG" \
	&& ! grep -qiE 'CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|ROLLBACK_IN_PROGRESS' "$LOG"; then
	echo "error: missing-SSM deploy reached CREATE_COMPLETE without failure markers" >&2
	exit 1
fi

# Prefer SSM-shaped text; stack/cli failure markers remain as fallback.
if grep -qiE 'ParameterNotFound|ParameterNotFoundException|Value not found at .ssm.|Unable to fetch parameters|Cannot resolve variable|ssm:/demo/rest|InvalidParameter|Parameter .* not found' "$LOG"; then
	echo "ok   missing SSM deploy failed as expected (rc=${rc})"
	echo "OK: serverless v3 sad missing-ssm (${BAD_SSM})"
	exit 0
fi

if grep -qiE 'CREATE_FAILED|ROLLBACK_COMPLETE|ROLLBACK_FAILED|Serverless Error|Cannot resolve' "$LOG"; then
	echo "ok   missing SSM deploy failed as expected (rc=${rc})"
	echo "OK: serverless v3 sad missing-ssm (${BAD_SSM})"
	exit 0
fi

echo "error: missing-SSM deploy did not show an SSM/resolve failure marker (rc=${rc})" >&2
tail -80 "$OUT/deploy-missing-ssm.clean.log" >&2 || true
exit 1
