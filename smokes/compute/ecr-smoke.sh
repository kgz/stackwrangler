#!/usr/bin/env bash
# #211: ECR repository + local registry push/pull + ECS task from the ECR URI.
#   1) get-login-password, docker push, docker pull, describe-images
#   2) execution role with ecr:BatchGetImage → task RUNNING and serves the pushed page
#   3) execution role without ecr:BatchGetImage → STOPPED
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
REGISTRY="${AWSBOX_ECR_REGISTRY:-127.0.0.1:5000}"
TS="$(date +%s)"
KEEP="${AWSBOX_AUTHZ_KEEP:-0}"

export AWS_ACCESS_KEY_ID="$KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET"
export AWS_DEFAULT_REGION="$REGION"
export DOCKER_CONFIG="${DOCKER_CONFIG:-$(mktemp -d)}"

aws() {
	command aws --endpoint-url "$EP" --region "$REGION" "$@"
}

REPO="awsbox-ecr-${TS}"
CLUSTER="awsbox-ecr-${TS}"
EXEC_ROLE="awsbox-ecr-exec-${TS}"
DENY_ROLE="awsbox-ecr-deny-${TS}"
FAMILY="awsbox-ecr-${TS}"
FAMILY_DENY="awsbox-ecr-deny-${TS}"
TOKEN="ecr-ok-${TS}"
BUILD="$(mktemp -d)"
TASK_ARNS=()

cleanup() {
	[[ "$KEEP" == "1" ]] && return 0
	for arn in "${TASK_ARNS[@]:-}"; do
		aws ecs stop-task --cluster "$CLUSTER" --task "$arn" >/dev/null 2>&1 || true
	done
	aws ecs delete-cluster --cluster "$CLUSTER" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$EXEC_ROLE" --policy-name ecr-pull >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$EXEC_ROLE" >/dev/null 2>&1 || true
	aws iam delete-role-policy --role-name "$DENY_ROLE" --policy-name ecr-no-pull >/dev/null 2>&1 || true
	aws iam delete-role --role-name "$DENY_ROLE" >/dev/null 2>&1 || true
	aws ecr delete-repository --repository-name "$REPO" --force >/dev/null 2>&1 || true
	docker rmi "${REGISTRY}/${REPO}:latest" >/dev/null 2>&1 || true
	rm -rf "$BUILD"
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

echo "$TOKEN" > "${BUILD}/index.html"
cat > "${BUILD}/Dockerfile" <<'EOF'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
EOF
docker build -t "${REGISTRY}/${REPO}:latest" "$BUILD" >/dev/null 2>&1
docker push "${REGISTRY}/${REPO}:latest" >/dev/null
docker rmi "${REGISTRY}/${REPO}:latest" >/dev/null
docker pull "${REGISTRY}/${REPO}:latest" >/dev/null
echo "OK: docker push/pull ${REGISTRY}/${REPO}:latest"

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
echo "OK: describe-images shows latest"

# #683: BuildKit provenance tags an OCI image index. Docker's default driver may
# refuse --provenance=true, so PUT an index via the registry API (same notify path).
INDEX_TAG="oci-index"
python3 - "$REGISTRY" "$REPO" "$INDEX_TAG" <<'PY'
import json, sys, urllib.request

registry, repo, tag = sys.argv[1:4]
accept = (
	"application/vnd.oci.image.index.v1+json,"
	"application/vnd.oci.image.manifest.v1+json,"
	"application/vnd.docker.distribution.manifest.v2+json"
)
req = urllib.request.Request(
	f"http://{registry}/v2/{repo}/manifests/latest",
	headers={"Accept": accept},
)
with urllib.request.urlopen(req) as resp:
	child = resp.read()
	child_digest = resp.headers.get("Docker-Content-Digest")
	child_ct = resp.headers.get("Content-Type") or "application/vnd.docker.distribution.manifest.v2+json"
if not child_digest:
	raise SystemExit("missing Docker-Content-Digest for latest")
index = {
	"schemaVersion": 2,
	"mediaType": "application/vnd.oci.image.index.v1+json",
	"manifests": [
		{
			"mediaType": child_ct.split(";", 1)[0].strip(),
			"size": len(child),
			"digest": child_digest,
			"platform": {"architecture": "amd64", "os": "linux"},
		}
	],
}
raw = json.dumps(index).encode()
put = urllib.request.Request(
	f"http://{registry}/v2/{repo}/manifests/{tag}",
	data=raw,
	method="PUT",
	headers={"Content-Type": "application/vnd.oci.image.index.v1+json"},
)
with urllib.request.urlopen(put) as resp:
	if resp.status not in (201, 202):
		raise SystemExit(f"index PUT status {resp.status}")
print(f"OK: registry PUT OCI index {repo}:{tag}")
PY

BATCH_MEDIA=""
for _ in $(seq 1 30); do
	BATCH_MEDIA="$(
		aws ecr batch-get-image \
			--repository-name "$REPO" \
			--image-ids "imageTag=${INDEX_TAG}" \
			--query 'images[0].imageManifestMediaType' \
			--output text 2>/dev/null || true
	)"
	[[ -n "$BATCH_MEDIA" && "$BATCH_MEDIA" != "None" ]] && break
	sleep 1
done
if [[ -z "$BATCH_MEDIA" || "$BATCH_MEDIA" == "None" ]]; then
	echo "FAIL: batch-get-image ImageNotFound for OCI index tag ${INDEX_TAG}" >&2
	exit 1
fi
if ! echo "$BATCH_MEDIA" | grep -q 'image.index'; then
	echo "FAIL: expected OCI index mediaType, got ${BATCH_MEDIA}" >&2
	exit 1
fi
echo "OK: batch-get-image ${INDEX_TAG} mediaType=${BATCH_MEDIA}"

TRUST='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
ALLOW_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:BatchCheckLayerAvailability"],"Resource":"*"}]}'
DENY_POLICY='{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"ecr:DescribeRepositories","Resource":"*"}]}'

aws iam create-role --role-name "$EXEC_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
EXEC_ARN="$(aws iam get-role --role-name "$EXEC_ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name ecr-pull --policy-document "$ALLOW_POLICY" >/dev/null

aws iam create-role --role-name "$DENY_ROLE" --assume-role-policy-document "$TRUST" >/dev/null
DENY_ARN="$(aws iam get-role --role-name "$DENY_ROLE" --query 'Role.Arn' --output text)"
aws iam put-role-policy --role-name "$DENY_ROLE" --policy-name ecr-no-pull --policy-document "$DENY_POLICY" >/dev/null

aws ecs create-cluster --cluster-name "$CLUSTER" >/dev/null

CDEFS="$(cat <<EOF
[{"name":"web","image":"${URI}:latest","essential":true,"memory":128,"portMappings":[{"containerPort":80,"protocol":"tcp"}]}]
EOF
)"

aws ecs register-task-definition \
	--family "$FAMILY" \
	--requires-compatibilities EC2 \
	--network-mode bridge \
	--execution-role-arn "$EXEC_ARN" \
	--container-definitions "$CDEFS" \
	>/dev/null

# Drop the local tag so the task has to pull from the registry.
docker rmi "${REGISTRY}/${REPO}:latest" >/dev/null

TASK_ARN="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
TASK_ARNS+=("$TASK_ARN")

STATUS=""
for _ in $(seq 1 60); do
	STATUS="$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" --query 'tasks[0].lastStatus' --output text)"
	[[ "$STATUS" == "RUNNING" || "$STATUS" == "STOPPED" ]] && break
	sleep 1
done
if [[ "$STATUS" != "RUNNING" ]]; then
	aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK_ARN" >&2
	echo "FAIL: ECR task not RUNNING (status=${STATUS})" >&2
	exit 1
fi

PORT=""
for _ in $(seq 1 20); do
	CID="$(docker ps -q --filter "label=localemu.task-arn=${TASK_ARN}" | head -1)"
	if [[ -n "$CID" ]]; then
		PORT="$(docker port "$CID" 80/tcp 2>/dev/null | awk -F: 'NR==1 {print $NF}')"
	fi
	[[ -n "$PORT" ]] && break
	sleep 1
done
if [[ -z "$PORT" ]]; then
	echo "FAIL: no host port for ECR task" >&2
	exit 1
fi
BODY="$(curl -sf -m 10 "http://127.0.0.1:${PORT}/")"
if [[ "$BODY" != "$TOKEN" ]]; then
	echo "FAIL: task body ${BODY:-empty} != ${TOKEN}" >&2
	exit 1
fi
echo "OK: ECS task pulled ${URI}:latest → ${TOKEN}"

aws ecs register-task-definition \
	--family "$FAMILY_DENY" \
	--requires-compatibilities EC2 \
	--network-mode bridge \
	--execution-role-arn "$DENY_ARN" \
	--container-definitions "$CDEFS" \
	>/dev/null

DENY_TASK="$(
	aws ecs run-task \
		--cluster "$CLUSTER" \
		--task-definition "$FAMILY_DENY" \
		--launch-type EC2 \
		--query 'tasks[0].taskArn' --output text
)"
TASK_ARNS+=("$DENY_TASK")

DENY_STATUS=""
DENY_REASON=""
for _ in $(seq 1 40); do
	read -r DENY_STATUS DENY_REASON < <(
		aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$DENY_TASK" --output json \
			| python3 -c 'import json,sys; t=json.load(sys.stdin)["tasks"][0]; print(t.get("lastStatus") or "", (t.get("stoppedReason") or "").replace("\n"," "))'
	)
	[[ "$DENY_STATUS" == "STOPPED" ]] && break
	sleep 1
done
if [[ "$DENY_STATUS" != "STOPPED" ]]; then
	echo "FAIL: role without BatchGetImage expected STOPPED, got ${DENY_STATUS}" >&2
	exit 1
fi
if ! echo "$DENY_REASON" | grep -qiE 'BatchGetImage|AccessDenied|not authorized|CannotPullContainerError'; then
	echo "FAIL: stoppedReason missing pull authz: ${DENY_REASON}" >&2
	exit 1
fi
echo "OK: execution role without ecr:BatchGetImage → STOPPED (${DENY_REASON:0:100})"

# #684: LocalEmu restart clears moto ECR; registry volume keeps blobs. Catalog
# resync must re-record tags without a new push (docker push would be a no-op).
echo "== #684 restart catalog resync =="
COMPOSE=(docker compose -f "$ROOT/docker-compose.yml")
"${COMPOSE[@]}" up -d --force-recreate --no-deps localstack >/dev/null
for _ in $(seq 1 90); do
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$EP/" || true)"
	[[ "$code" =~ ^[12345][0-9][0-9]$ ]] && break
	sleep 2
done
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$EP/" || true)"
if [[ ! "$code" =~ ^[12345][0-9][0-9]$ ]]; then
	echo "FAIL: LocalEmu not ready after recreate (${code})" >&2
	exit 1
fi

RESYNC_TAGS=""
for _ in $(seq 1 60); do
	RESYNC_TAGS="$(
		aws ecr describe-images --repository-name "$REPO" \
			--query 'imageDetails[].imageTags[]' --output text 2>/dev/null || true
	)"
	echo "$RESYNC_TAGS" | grep -qw latest && break
	sleep 2
done
if ! echo "$RESYNC_TAGS" | grep -qw latest; then
	echo "FAIL: after LocalEmu recreate, describe-images missing latest (${RESYNC_TAGS:-empty})" >&2
	exit 1
fi
if ! echo "$RESYNC_TAGS" | grep -qw "$INDEX_TAG"; then
	echo "FAIL: after LocalEmu recreate, missing OCI index tag ${INDEX_TAG} (${RESYNC_TAGS})" >&2
	exit 1
fi
echo "OK: catalog resync restored tags after LocalEmu recreate (${RESYNC_TAGS})"

# delete-repository + create-repository should adopt registry tags (#684).
aws ecr delete-repository --repository-name "$REPO" --force >/dev/null
aws ecr create-repository --repository-name "$REPO" >/dev/null
ADOPT_TAGS=""
for _ in $(seq 1 30); do
	ADOPT_TAGS="$(
		aws ecr describe-images --repository-name "$REPO" \
			--query 'imageDetails[].imageTags[]' --output text 2>/dev/null || true
	)"
	echo "$ADOPT_TAGS" | grep -qw latest && break
	sleep 1
done
if ! echo "$ADOPT_TAGS" | grep -qw latest; then
	echo "FAIL: create-repository did not adopt registry tag latest (${ADOPT_TAGS:-empty})" >&2
	exit 1
fi
echo "OK: create-repository adopted registry tags (${ADOPT_TAGS})"

echo "OK: ecr smoke (push/pull / ecs pull / deny BatchGetImage / restart resync)"
