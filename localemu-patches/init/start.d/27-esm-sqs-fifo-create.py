"""Allow CreateEventSourceMapping on SQS FIFO queues (#499).

LocalEmu remaps FIFO EventSourceArn to the synthetic service name `sqs-fifo`
for batch-size limits, then calls `load_service(service)` for the duplicate-
mapping conflict message. botocore has no `sqs-fifo` service, so create
returns InternalError before the mapping exists. Map `sqs-fifo` → `sqs` for
that lookup only (same service_id / conflict wording as standard SQS).
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.esm_sqs_fifo_create")


def _patch() -> None:
    import localemu.services.lambda_.provider as provider_mod

    if getattr(provider_mod.load_service, "_awsbox_sqs_fifo", False):
        return

    original = provider_mod.load_service

    def load_service(service, *args, **kwargs):
        if service == "sqs-fifo":
            service = "sqs"
        return original(service, *args, **kwargs)

    load_service._awsbox_sqs_fifo = True
    provider_mod.load_service = load_service
    LOG.info("awsbox ESM SQS FIFO create (load_service sqs-fifo→sqs) applied")


_patch()
