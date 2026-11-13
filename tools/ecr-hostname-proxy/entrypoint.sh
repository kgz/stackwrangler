#!/usr/bin/env bash
# TLS edge for <account>.dkr.ecr.<region>.amazonaws.com → ecr-registry (#218).
set -euo pipefail

CERT_DIR="${ECR_HOSTNAME_CERT_DIR:-/certs}"
TLS_PID_FILE="${ECR_HOSTNAME_TLS_PID:-/var/run/ecr-hostname-tls.pid}"
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

export ECR_HOSTNAME_CERT_DIR="$CERT_DIR"
export ECR_HOSTNAME_TLS_PID="$TLS_PID_FILE"
export ECR_REGISTRY_URL

echo "ecr-hostname: TLS :443 → ${ECR_REGISTRY_URL}"
exec python3 -u /opt/ecr-hostname/tls_proxy.py
