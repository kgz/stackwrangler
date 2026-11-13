# Orchestrator: compose-on-host-Docker via sock. Not a fat all-services image.
# See docs/docker-install.md for layout tradeoffs.
FROM docker:27-cli

RUN apk add --no-cache bash curl python3 \
	&& docker compose version >/dev/null

COPY .env.example /opt/stackwrangler/.env.example
COPY docker/compose.release.yml /opt/stackwrangler/docker/compose.release.yml
COPY bin/stackwrangler-env.sh /opt/stackwrangler/bin/stackwrangler-env.sh
COPY bin/stackwrangler-profile /opt/stackwrangler/bin/stackwrangler-profile
COPY bin/stackwrangler-wait-healthy.sh /opt/stackwrangler/bin/stackwrangler-wait-healthy.sh
COPY bin/stackwrangler-dev-apply-hook.sh /opt/stackwrangler/bin/stackwrangler-dev-apply-hook.sh
COPY docker/bin/stackwrangler-image /usr/local/bin/stackwrangler
RUN chmod +x /usr/local/bin/stackwrangler /opt/stackwrangler/bin/stackwrangler-profile

ARG IMAGE_VERSION=dev
RUN printf '%s\n' "$IMAGE_VERSION" >/opt/stackwrangler/IMAGE_VERSION

ENV STACKWRANGLER_OPT_ROOT=/opt/stackwrangler \
	STACKWRANGLER_DATA=/data \
	STACKWRANGLER_COMPOSE_FILE=/opt/stackwrangler/docker/compose.release.yml \
	COMPOSE_PROJECT_NAME=stackwrangler

VOLUME ["/data"]
ENTRYPOINT ["/usr/local/bin/stackwrangler"]
CMD ["help"]
