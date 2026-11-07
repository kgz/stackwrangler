# Shared S3 + LocalEmu readiness wait for bin/stackwrangler and image CLI.
# Source after COMPOSE=(...) and endpoint_url / iam_endpoint_url are defined.
#
#   # shellcheck disable=SC1091
#   source "$ROOT/bin/stackwrangler-wait-healthy.sh"
#
wait_healthy() {
	local ep i code
	ep="$(endpoint_url)"
	for i in $(seq 1 40); do
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "${ep}/" || true)"
		if [[ "$code" =~ ^[12345][0-9][0-9]$ ]]; then
			break
		fi
		sleep 1
		if [[ "$i" -eq 40 ]]; then
			echo "error: S3 endpoint did not become ready: ${ep}" >&2
			"${COMPOSE[@]}" ps >&2 || true
			"${COMPOSE[@]}" logs --tail 40 s3 >&2 || true
			exit 1
		fi
	done

	ep="$(iam_endpoint_url)"
	for i in $(seq 1 90); do
		if curl -sf --max-time 2 "${ep}/_localstack/health" >/dev/null 2>&1 \
			|| curl -sf --max-time 2 "${ep}/_localemu/health" >/dev/null 2>&1; then
			return 0
		fi
		code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "${ep}/" || true)"
		if [[ "$code" =~ ^[12345][0-9][0-9]$ ]]; then
			return 0
		fi
		sleep 1
	done
	echo "error: IAM endpoint did not become ready: ${ep}" >&2
	"${COMPOSE[@]}" ps >&2 || true
	"${COMPOSE[@]}" logs --tail 60 localstack >&2 || true
	exit 1
}
