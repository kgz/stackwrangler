"""Log AWS requests on receipt (not only completion) (#718).

``ResponseLogger`` writes ``localemu.request.aws`` lines after the handler
returns. A multi-minute gap with only healthchecks then looks identical for
"client never sent Describe" vs "Describe blocked inside LocalEmu".

This handler runs after ``parse_service_request`` (via the custom request
composite) and logs ``AWS <svc>.<op> received`` immediately so stalls are
attributable.
"""

from __future__ import annotations

import logging
import time

LOG = logging.getLogger("localemu.request.aws")

_HANDLER_TAG = "awsbox.aws_request_receipt"
_CTX_ATTR = "_awsbox_request_receipt_mono"


class AwsRequestReceiptHandler:
    """Request-chain handler: log operation start + stash monotonic clock."""

    _le_handler_tag = _HANDLER_TAG

    def __call__(self, chain, context, response) -> None:
        if getattr(context, "is_internal_call", False):
            return
        service = getattr(context, "service", None)
        operation = getattr(context, "operation", None)
        if service is None or operation is None:
            return
        try:
            setattr(context, _CTX_ATTR, time.monotonic())
        except Exception:
            pass
        LOG.info(
            "AWS %s.%s received",
            service.service_name,
            operation.name,
            extra={
                "account_id": getattr(context, "account_id", None),
                "region": getattr(context, "region", None),
            },
        )


class AwsRequestDurationHandler:
    """Response-chain handler: warn when an AWS op took too long."""

    _le_handler_tag = "awsbox.aws_request_duration"

    def __call__(self, chain, context, response) -> None:
        if getattr(context, "is_internal_call", False):
            return
        service = getattr(context, "service", None)
        operation = getattr(context, "operation", None)
        started = getattr(context, _CTX_ATTR, None)
        if service is None or operation is None or started is None:
            return
        elapsed = time.monotonic() - float(started)
        # Terraform RDS create waiter polls every 10s; anything multi-second
        # on Describe is already suspicious for LocalEmu.
        if elapsed < 2.0:
            return
        LOG.warning(
            "AWS %s.%s slow: %.2fs",
            service.service_name,
            operation.name,
            elapsed,
        )


def _install() -> None:
    from localemu.aws.handlers import (
        run_custom_response_handlers,
        serve_custom_service_request_handlers,
    )

    req_handlers = serve_custom_service_request_handlers.handlers
    if not any(getattr(h, "_le_handler_tag", None) == _HANDLER_TAG for h in req_handlers):
        req_handlers.insert(0, AwsRequestReceiptHandler())

    resp_handlers = run_custom_response_handlers.handlers
    tag = AwsRequestDurationHandler._le_handler_tag
    if not any(getattr(h, "_le_handler_tag", None) == tag for h in resp_handlers):
        resp_handlers.insert(0, AwsRequestDurationHandler())

    LOG.info("awsbox AWS request receipt logging enabled")


_install()
