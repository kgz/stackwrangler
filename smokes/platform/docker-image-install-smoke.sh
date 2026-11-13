#!/usr/bin/env bash
# Public image install path (#487): cold-machine shape.
# Build artifacts may use the checkout; the *run* path copies install/stackwrangler
# into a temp dir and never invokes monorepo root compose / ./bin/stackwrangler.
# Docs: docs/docker-install.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

TAG="${STACKWRANGLER_SMOKE_TAG:-local}"
HOME_DIR="${STACKWRANGLER_SMOKE_HOME:-$(mktemp -d /tmp/stackwrangler-img-smoke.XXXXXX)}"
AWS_DIR="${STACKWRANGLER_SMOKE_AWS:-$(mktemp -d /tmp/stackwrangler-img-aws.XXXXXX)}"
# Isolated “machine” — only the public CLI script, no repo checkout.
COLD_DIR="${STACKWRANGLER_SMOKE_COLD:-$(mktemp -d /tmp/stackwrangler-img-cold.XXXXXX)}"
PROJECT="${COMPOSE_PROJECT_NAME:-stackwrangler-img-smoke}"
CLI="${COLD_DIR}/stackwrangler"

# High ports — avoid shared LocalEmu / SeaweedFS on this machine.
export STACKWRANGLER_S3_HOST_PORT="${STACKWRANGLER_S3_HOST_PORT:-18333}"
export STACKWRANGLER_LOCALEMU_HOST_PORT="${STACKWRANGLER_LOCALEMU_HOST_PORT:-14566}"
export STACKWRANGLER_CONSOLE_HOST_PORT="${STACKWRANGLER_CONSOLE_HOST_PORT:-13000}"
export STACKWRANGLER_ECR_HOST_PORT="${STACKWRANGLER_ECR_HOST_PORT:-15050}"
export STACKWRANGLER_SFTP_HOST_PORT="${STACKWRANGLER_SFTP_HOST_PORT:-12222}"
export STACKWRANGLER_TRANSFER_SFTP_PORT="${STACKWRANGLER_TRANSFER_SFTP_PORT:-12222}"
export STACKWRANGLER_ECS_CREDS_PORT="${STACKWRANGLER_ECS_CREDS_PORT:-14571}"
export STACKWRANGLER_ENDPOINT="http://127.0.0.1:${STACKWRANGLER_S3_HOST_PORT}"
export STACKWRANGLER_IAM_ENDPOINT="http://127.0.0.1:${STACKWRANGLER_LOCALEMU_HOST_PORT}"

export STACKWRANGLER_IMAGE="stackwrangler:${TAG}"
export STACKWRANGLER_LOCAL_IMAGES=1
export STACKWRANGLER_LOCALEMU_IMAGE="stackwrangler-localemu:${TAG}"
export STACKWRANGLER_CONSOLE_IMAGE="stackwrangler-console:${TAG}"
export STACKWRANGLER_ECR_IMAGE="stackwrangler-ecr:${TAG}"
export STACKWRANGLER_ECR_HOSTNAME_IMAGE="stackwrangler-ecr-hostname:${TAG}"
export STACKWRANGLER_HOME="$HOME_DIR"
export AWS_SHARED_CREDENTIALS_FILE="${AWS_DIR}/credentials"
export AWS_CONFIG_FILE="${AWS_DIR}/config"
export COMPOSE_PROJECT_NAME="$PROJECT"

cleanup() {
	if [[ -x "$CLI" ]]; then
		"$CLI" down -v --remove-profile >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT

if [[ "${STACKWRANGLER_SMOKE_SKIP_BUILD:-0}" != "1" ]]; then
	# Artifact build only — not the public run path.
	"$ROOT/bin/build-release-images.sh" --tag "$TAG"
fi

rm -rf "${HOME_DIR:?}/"* "${AWS_DIR:?}/"* 2>/dev/null || true
mkdir -p "$HOME_DIR" "$AWS_DIR" "$COLD_DIR"
cp "$ROOT/install/stackwrangler" "$CLI"
chmod +x "$CLI"

# Run exclusively from the cold dir (no monorepo $ROOT on cwd / compose).
cd "$COLD_DIR"
case "$(pwd -P)" in
"$ROOT" | "$ROOT"/*)
	echo "FAIL: cold smoke must not run under monorepo root ($ROOT)" >&2
	exit 1
	;;
esac
[[ ! -f "$COLD_DIR/docker-compose.yml" ]] || {
	echo "FAIL: unexpected docker-compose.yml in cold dir" >&2
	exit 1
}

"$CLI" up --force

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${STACKWRANGLER_CONSOLE_HOST_PORT}/" || true)"
[[ "$code" =~ ^[23][0-9][0-9]$ ]] || {
	echo "FAIL: console HTTP ${code} at :${STACKWRANGLER_CONSOLE_HOST_PORT}" >&2
	exit 1
}

aws --profile local --endpoint-url "$STACKWRANGLER_IAM_ENDPOINT" sts get-caller-identity >/dev/null
aws --profile local s3 ls >/dev/null

# Sad: orchestrator without docker.sock must fail fast (no silent success).
set +e
out="$(docker run --rm --network host \
	-v "${HOME_DIR}:/data" \
	-e STACKWRANGLER_DATA=/data \
	-e STACKWRANGLER_LOCAL_IMAGES=1 \
	"$STACKWRANGLER_IMAGE" up 2>&1)"
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
	echo "FAIL: up without docker.sock should fail" >&2
	exit 1
fi
printf '%s\n' "$out" | grep -qi 'docker.sock' || {
	echo "FAIL: expected docker.sock error, got: $out" >&2
	exit 1
}

echo "OK docker-image-install-smoke (cold dir + console + sts + sock refusal)"
