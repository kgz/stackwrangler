#!/usr/bin/env bash
# Build public-path images locally (no GHCR push). For smoke / pre-release.
# Usage: ./bin/build-release-images.sh [--tag local]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TAG=local
while [[ $# -gt 0 ]]; do
	case "$1" in
	--tag)
		TAG="${2:?}"
		shift 2
		;;
	*)
		echo "unknown arg: $1" >&2
		exit 1
		;;
	esac
done

DIGEST="$(grep -E '^sha256:[0-9a-f]{64}$' localemu-patches/IMAGE_DIGEST | tail -n1)"
[[ -n "$DIGEST" ]] || {
	echo "error: localemu-patches/IMAGE_DIGEST missing" >&2
	exit 1
}

echo "building stackwrangler-localemu:${TAG} (from localemu@${DIGEST})"
docker build \
	-f docker/Dockerfile.localemu \
	--build-arg "LOCALEMU_DIGEST=${DIGEST}" \
	-t "stackwrangler-localemu:${TAG}" \
	.

echo "building stackwrangler-ecr:${TAG}"
docker build -f docker/Dockerfile.ecr -t "stackwrangler-ecr:${TAG}" .

echo "building stackwrangler-ecr-hostname:${TAG}"
docker build -f docker/Dockerfile.ecr-hostname -t "stackwrangler-ecr-hostname:${TAG}" .

echo "building stackwrangler-console:${TAG}"
docker build -f docker/Dockerfile.console -t "stackwrangler-console:${TAG}" .

echo "building stackwrangler:${TAG} (orchestrator)"
docker build \
	-f docker/Dockerfile \
	--build-arg "IMAGE_VERSION=${TAG}" \
	-t "stackwrangler:${TAG}" \
	.

cat <<EOF

Built:
  stackwrangler:${TAG}
  stackwrangler-localemu:${TAG}
  stackwrangler-console:${TAG}
  stackwrangler-ecr:${TAG}
  stackwrangler-ecr-hostname:${TAG}

Smoke (example — alternate ECR port if :5000 is busy):
  export STACKWRANGLER_IMAGE=stackwrangler:${TAG}
  export STACKWRANGLER_LOCAL_IMAGES=1
  export STACKWRANGLER_LOCALEMU_IMAGE=stackwrangler-localemu:${TAG}
  export STACKWRANGLER_CONSOLE_IMAGE=stackwrangler-console:${TAG}
  export STACKWRANGLER_ECR_IMAGE=stackwrangler-ecr:${TAG}
  export STACKWRANGLER_ECR_HOSTNAME_IMAGE=stackwrangler-ecr-hostname:${TAG}
  export STACKWRANGLER_ECR_HOST_PORT=5050
  export COMPOSE_PROJECT_NAME=stackwrangler-local
  ./install/stackwrangler up
  ./install/stackwrangler down -v

EOF
