#!/usr/bin/env bash
# #219: Lambda PackageType=Image pull from ECR URI with function-role authz.
#   1) push a Lambda image to the local registry; CreateFunction with ImageUri
#   2) role with ecr:BatchGetImage → invoke succeeds (handler runs)
#   3) role without ecr:BatchGetImage → invoke fails before the handler
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
REGISTRY="${AWSBOX_ECR_REGISTRY:-127.0.0.1:${STACKWRANGLER_ECR_HOST_PORT:-${AWSBOX_ECR_HOST_PORT:-5000}}}"
TS="$(date +%s)"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"
TOKEN="lambda-ecr-ok-${TS}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export DOCKER_CONFIG="${DOCKER_CONFIG:-$(mktemp -d)}"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

REPO="awsbox-lambda-ecr-${TS}"
ALLOW_ROLE="awsbox-lambda-ecr-allow-${TS}"
DENY_ROLE="awsbox-lambda-ecr-deny-${TS}"
FN_ALLOW="awsbox-lambda-ecr-allow-${TS}"
FN_DENY="awsbox-lambda-ecr-deny-${TS}"
BUILD="$(mktemp -d)"
OUT_ALLOW="/tmp/awsbox-lambda-ecr-allow-${TS}.json"
OUT_DENY="/tmp/awsbox-lambda-ecr-deny-${TS}.json"

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	aws lambda delete-function --function-name "$FN_ALLOW" >/dev/null 2>&1 || true
	aws lambda delete-function --function-name "$FN_DENY" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$ALLOW_ROLE" --policy-name ecr-pull >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$ALLOW_ROLE" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$DENY_ROLE" --policy-name ecr-no-pull >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$DENY_ROLE" >/dev/null 2>&1 || true
	aws ecr delete-repository --repository-name "$REPO" --force >/dev/null 2>&1 || true
	docker rmi "${REGISTRY}/${REPO}:latest" >/dev/null 2>&1 || true
	rm -rf "$BUILD" "$OUT_ALLOW" "$OUT_DENY"
	if [[ "${DOCKER_CONFIG:-}" == /tmp/* ]]; then
		rm -rf "$DOCKER_CONFIG"
	fi
}
trap cleanup EXIT

for _ in $(seq 1 30); do
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://${REGISTRY}/v2/" || true)"
	[[ "$code" == "200" || "$code" == "401" ]] && break
	sleep 1
done
if [[ "$code" != "200" && "$code" != "401" ]]; then
	echo "FAIL: local registry ${REGISTRY} not ready (http ${code:-?})" >&2
	exit 1
fi

aws ecr create-repository --repository-name "$REPO" >/dev/null
URI="$(aws ecr describe-repositories --repository-names "$REPO" --query 'repositories[0].repositoryUri' --output text)"
echo "URI=${URI}"
if ! echo "$URI" | grep -qE '^[0-9]+\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/'; then
	echo "FAIL: repositoryUri is not an ECR hostname: ${URI}" >&2
	exit 1
fi

PASS="$(aws ecr get-login-password)"
if [[ -z "$PASS" ]]; then
	echo "FAIL: get-login-password empty" >&2
	exit 1
fi
echo "$PASS" | docker login --username AWS --password-stdin "$REGISTRY" >/dev/null 2>&1

cat > "${BUILD}/app.js" <<EOF
exports.handler = async () => ({ ok: true, token: "${TOKEN}" });
EOF
cat > "${BUILD}/Dockerfile" <<'EOF'
FROM public.ecr.aws/lambda/nodejs:20
COPY app.js ${LAMBDA_TASK_ROOT}/
CMD ["app.handler"]
EOF
docker build -t "${REGISTRY}/${REPO}:latest" "$BUILD" >/dev/null
docker push "${REGISTRY}/${REPO}:latest" >/dev/null
echo "OK: pushed Lambda image ${REGISTRY}/${REPO}:latest"

DESCRIBED=""
for _ in $(seq 1 30); do
	DESCRIBED="$(aws ecr describe-images --repository-name "$REPO" --query 'imageDetails[].imageTags[]' --output text 2>/dev/null || true)"
	echo "$DESCRIBED" | grep -qw latest && break
	sleep 1
done
if ! echo "$DESCRIBED" | grep -qw latest; then
	echo "FAIL: describe-images missing tag latest (${DESCRIBED:-empty})" >&2
	exit 1
fi

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ALLOW_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:BatchCheckLayerAvailability"],"Resource":"*"}]}'
DENY_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"ecr:DescribeRepositories","Resource":"*"}]}'

aws iam create-role --role-name "$ALLOW_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
ALLOW_ARN="$(aws iam get-role --role-name "$ALLOW_ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$ALLOW_ROLE" --policy-name ecr-pull --policy-document "$ALLOW_POLICY" >/dev/null

aws iam create-role --role-name "$DENY_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
DENY_ARN="$(aws iam get-role --role-name "$DENY_ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$DENY_ROLE" --policy-name ecr-no-pull --policy-document "$DENY_POLICY" >/dev/null

# Drop local tag so cold start must pull (authz still runs either way).
docker rmi "${REGISTRY}/${REPO}:latest" >/dev/null 2>&1 || true

aws lambda create-function \
	--function-name "$FN_ALLOW" \
	--package-type Image \
	--code "ImageUri=${URI}:latest" \
	--role "$ALLOW_ARN" \
	--image-config 'Command=["app.handler"]' \
	>/dev/null

wait_active() {
	local fn="$1" state=""
	for _ in $(seq 1 60); do
		state="$(
			aws lambda get-function --function-name "$fn" \
				--query 'Configuration.State' --output text 2>/dev/null || echo Pending
		)"
		[[ "$state" == "Active" ]] && return 0
		sleep 2
	done
	echo "FAIL: ${fn} never Active (state=${state})" >&2
	return 1
}

wait_active "$FN_ALLOW"

INVOKE_META="$(
	aws lambda invoke \
		--function-name "$FN_ALLOW" \
		--cli-binary-format raw-in-base64-out \
		--payload '{}' \
		"$OUT_ALLOW" \
		--output json
)"
ALLOW_STATUS="$(echo "$INVOKE_META" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("StatusCode",""))')"
ALLOW_ERR="$(echo "$INVOKE_META" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("FunctionError") or "")')"
ALLOW_BODY="$(cat "$OUT_ALLOW")"
if [[ "$ALLOW_STATUS" != "200" || -n "$ALLOW_ERR" ]]; then
	echo "FAIL: allow invoke StatusCode=${ALLOW_STATUS} FunctionError=${ALLOW_ERR} body=${ALLOW_BODY}" >&2
	exit 1
fi
if ! echo "$ALLOW_BODY" | grep -q "$TOKEN"; then
	echo "FAIL: allow handler did not run (body=${ALLOW_BODY})" >&2
	exit 1
fi
echo "OK: Lambda ImageUri ${URI}:latest invoked → ${TOKEN}"

aws lambda create-function \
	--function-name "$FN_DENY" \
	--package-type Image \
	--code "ImageUri=${URI}:latest" \
	--role "$DENY_ARN" \
	--image-config 'Command=["app.handler"]' \
	>/dev/null

wait_active "$FN_DENY"

DENY_ERR_FILE="/tmp/awsbox-lambda-ecr-deny-err-${TS}.txt"
set +e
DENY_META="$(
	aws lambda invoke \
		--function-name "$FN_DENY" \
		--cli-binary-format raw-in-base64-out \
		--payload '{}' \
		"$OUT_DENY" \
		--output json 2>"$DENY_ERR_FILE"
)"
DENY_RC=$?
set -e
DENY_BODY="$(cat "$OUT_DENY" 2>/dev/null || true)"
DENY_STDERR="$(cat "$DENY_ERR_FILE" 2>/dev/null || true)"
rm -f "$DENY_ERR_FILE"
DENY_ERR=""
DENY_STATUS=""
if [[ -n "$DENY_META" ]]; then
	DENY_STATUS="$(echo "$DENY_META" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("StatusCode",""))' 2>/dev/null || true)"
	DENY_ERR="$(echo "$DENY_META" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("FunctionError") or "")' 2>/dev/null || true)"
fi
DENY_BLOB="${DENY_ERR} ${DENY_BODY} ${DENY_META} ${DENY_STDERR}"
if echo "$DENY_BODY" | grep -q "$TOKEN"; then
	echo "FAIL: deny role still ran handler (body=${DENY_BODY})" >&2
	exit 1
fi
if ! echo "$DENY_BLOB" | grep -qiE 'BatchGetImage|AccessDenied|not authorized|CannotPullContainerError'; then
	echo "FAIL: deny invoke missing pull authz (rc=${DENY_RC} status=${DENY_STATUS} err=${DENY_ERR} body=${DENY_BODY} stderr=${DENY_STDERR})" >&2
	exit 1
fi
echo "OK: function role without ecr:BatchGetImage → cold start denied before handler"
echo "OK: lambda-ecr smoke (ImageUri invoke / deny BatchGetImage)"
