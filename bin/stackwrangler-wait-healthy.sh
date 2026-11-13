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

	# HTTP alone is not enough: weed mini with volume.max auto=0 on a full disk
	# still answers 403 while PutObject returns InternalError (no free volumes).
	wait_s3_writable "$ep"

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

# Probe CreateBucket + PutObject so up fails fast when Seaweed has no volume capacity.
wait_s3_writable() {
	local ep="${1:-}"
	local key secret region bucket i
	if ! command -v aws >/dev/null 2>&1; then
		return 0
	fi
	# Caller already loaded .env via endpoint_url (load_root_env / load_data_env).
	key="$(sw_env STACKWRANGLER_ACCESS_KEY AWSBOX_ACCESS_KEY stackwrangler)"
	secret="$(sw_env STACKWRANGLER_SECRET_KEY AWSBOX_SECRET_KEY stackwranglerstackwrangler)"
	region="$(sw_env STACKWRANGLER_REGION AWSBOX_REGION us-east-1)"
	bucket="sw-health-$$-$(date +%s)"
	for i in $(seq 1 30); do
		if AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" \
			AWS_DEFAULT_REGION="$region" AWS_EC2_METADATA_DISABLED=true \
			aws --endpoint-url "$ep" --region "$region" s3 mb "s3://${bucket}" >/dev/null 2>&1 \
			&& printf 'ok' | AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" \
				AWS_DEFAULT_REGION="$region" AWS_EC2_METADATA_DISABLED=true \
				aws --endpoint-url "$ep" --region "$region" s3 cp - "s3://${bucket}/.health" >/dev/null 2>&1; then
			AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" \
				AWS_DEFAULT_REGION="$region" AWS_EC2_METADATA_DISABLED=true \
				aws --endpoint-url "$ep" --region "$region" s3 rb "s3://${bucket}" --force >/dev/null 2>&1 || true
			return 0
		fi
		AWS_ACCESS_KEY_ID="$key" AWS_SECRET_ACCESS_KEY="$secret" \
			AWS_DEFAULT_REGION="$region" AWS_EC2_METADATA_DISABLED=true \
			aws --endpoint-url "$ep" --region "$region" s3 rb "s3://${bucket}" --force >/dev/null 2>&1 || true
		sleep 1
	done
	echo "error: S3 PutObject did not succeed (Seaweed may have no free volumes / disk full): ${ep}" >&2
	"${COMPOSE[@]}" ps >&2 || true
	"${COMPOSE[@]}" logs --tail 60 s3 >&2 || true
	exit 1
}
