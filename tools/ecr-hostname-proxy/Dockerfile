# TLS edge for ECR repositoryUri hostnames → distribution registry (#218).
# Reuses tools/aws-endpoint-redirect/tls_proxy.py (build context = tools/).
FROM python:3.12-slim-bookworm

RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		openssl \
		ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

COPY ecr-hostname-proxy/requirements.txt /opt/ecr-hostname/requirements.txt
RUN pip install --no-cache-dir -r /opt/ecr-hostname/requirements.txt

COPY aws-endpoint-redirect/tls_proxy.py /opt/ecr-hostname/tls_proxy.py
COPY ecr-hostname-proxy/entrypoint.sh ecr-hostname-proxy/healthcheck.sh /opt/ecr-hostname/
RUN chmod +x /opt/ecr-hostname/entrypoint.sh /opt/ecr-hostname/tls_proxy.py /opt/ecr-hostname/healthcheck.sh

ENV AWS_REDIRECT_CERT_DIR=/certs \
	LOCALEMU_URL=http://ecr-registry:5000 \
	AWS_REDIRECT_TLS_PID=/var/run/ecr-hostname-tls.pid

EXPOSE 443/tcp
VOLUME ["/certs"]

ENTRYPOINT ["/opt/ecr-hostname/entrypoint.sh"]
