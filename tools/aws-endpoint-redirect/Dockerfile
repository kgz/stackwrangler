# Dual-role AWS endpoint redirect: dnsmasq + TLS edge → LocalEmu (#464).
FROM python:3.12-slim-bookworm

RUN apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
		dnsmasq \
		dnsutils \
		iproute2 \
		openssl \
		ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

COPY requirements.txt /opt/aws-redirect/requirements.txt
RUN pip install --no-cache-dir -r /opt/aws-redirect/requirements.txt

COPY tls_proxy.py entrypoint.sh healthcheck.sh /opt/aws-redirect/
RUN chmod +x /opt/aws-redirect/entrypoint.sh /opt/aws-redirect/tls_proxy.py /opt/aws-redirect/healthcheck.sh

ENV AWS_REDIRECT_CERT_DIR=/certs \
	LOCALEMU_URL=http://localstack:4566 \
	AWS_REDIRECT_DNS_LOG=/var/log/aws-redirect-dnsmasq.log \
	AWS_REDIRECT_TLS_PID=/var/run/aws-redirect-tls.pid

EXPOSE 53/udp 53/tcp 443/tcp
VOLUME ["/certs"]

ENTRYPOINT ["/opt/aws-redirect/entrypoint.sh"]
