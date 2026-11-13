#!/usr/bin/env bash
# TLS edge for <account>.dkr.ecr.<region>.amazonaws.com → ecr-registry (#218).
# Runs shared tools/aws-endpoint-redirect/tls_proxy.py (LOCALEMU_URL = registry).
set -euo pipefail

CERT_DIR="${ECR_HOSTNAME_CERT_DIR:-${AWS_REDIRECT_CERT_DIR:-/certs}}"
TLS_PID_FILE="${ECR_HOSTNAME_TLS_PID:-${AWS_REDIRECT_TLS_PID:-/var/run/ecr-hostname-tls.pid}}"
ECR_REGISTRY_URL="${ECR_REGISTRY_URL:-http://ecr-registry:5000}"

mkdir -p "$CERT_DIR" /var/run

if [[ ! -f "$CERT_DIR/ca.key" || ! -f "$CERT_DIR/ca.crt" ]]; then
	echo "ecr-hostname: generating local CA under ${CERT_DIR}"
	openssl req -x509 -newkey rsa:2048 -nodes \
		-keyout "$CERT_DIR/ca.key" \
		-out "$CERT_DIR/ca.crt" \
		-days 3650 \
		-subj "/CN=stackwrangler ECR hostname CA/O=stackwrangler/OU=ecr-hostname"
	chmod 644 "$CERT_DIR/ca.crt"
	chmod 600 "$CERT_DIR/ca.key"
fi
cp -f "$CERT_DIR/ca.crt" "$CERT_DIR/ca.pem" 2>/dev/null || true

# Shared tls_proxy.py reads AWS_REDIRECT_* + LOCALEMU_URL.
export AWS_REDIRECT_CERT_DIR="$CERT_DIR"
export AWS_REDIRECT_TLS_PID="$TLS_PID_FILE"
export LOCALEMU_URL="$ECR_REGISTRY_URL"

echo "ecr-hostname: TLS :443 → ${LOCALEMU_URL} (shared tls_proxy.py)"
exec python3 -u /opt/ecr-hostname/tls_proxy.py
