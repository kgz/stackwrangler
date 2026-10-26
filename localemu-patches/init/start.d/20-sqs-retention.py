"""Refuse MessageRetentionPeriod outside 60–1209600 on CreateQueue / SetQueueAttributes (#363).

Real AWS returns InvalidAttributeValue. LocalEmu accepts values above 14 days, so
stacks that pass locally can fail on deploy.
"""

from __future__ import annotations

import logging
import sys

if "/opt/awsbox/esm" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/esm")

import awsbox_esm_common as esm  # noqa: E402

LOG = logging.getLogger("localemu.awsbox.sqs_retention")

_RETENTION_MIN = 60
_RETENTION_MAX = 1_209_600  # 14 days


def _attributes_from_request(request) -> dict | None:
    attrs = esm.request_get(request, "Attributes")
    if attrs is None:
        return None
    if isinstance(attrs, dict):
        return attrs
    if callable(getattr(attrs, "items", None)):
        return dict(attrs.items())
    return None


def _check_retention(attributes: dict) -> None:
    raw = attributes.get("MessageRetentionPeriod")
    if raw is None:
        return
    try:
        value = int(raw)
    except (TypeError, ValueError):
        from localemu.services.sqs.exceptions import InvalidAttributeValue

        raise InvalidAttributeValue(
            "Invalid value for the parameter MessageRetentionPeriod."
        )
    if _RETENTION_MIN <= value <= _RETENTION_MAX:
        return

    from localemu.services.sqs.exceptions import InvalidAttributeValue

    raise InvalidAttributeValue(
        "Invalid value for the parameter MessageRetentionPeriod."
    )


def _enforce_from_request(context, request) -> None:
    service = getattr(context, "service", None)
    operation = getattr(context, "operation", None)
    if getattr(service, "service_name", None) != "sqs":
        return
    op = getattr(operation, "name", None)
    if op not in ("CreateQueue", "SetQueueAttributes"):
        return
    attrs = _attributes_from_request(request)
    if not attrs:
        return
    _check_retention(attrs)


def _patch_validate(cls) -> None:
    original = cls.validate_queue_attributes

    def validate_queue_attributes(self, attributes):
        original(self, attributes)
        if attributes:
            _check_retention(attributes)

    cls.validate_queue_attributes = validate_queue_attributes


def _patch() -> None:
    from localemu.aws.skeleton import Skeleton
    from localemu.services.sqs.models import FifoQueue, StandardQueue

    if getattr(Skeleton, "_awsbox_sqs_retention", False):
        return

    _patch_validate(StandardQueue)
    _patch_validate(FifoQueue)

    original = Skeleton.dispatch_request

    def dispatch_request(self, serializer, context, instance):
        _enforce_from_request(context, instance)
        return original(self, serializer, context, instance)

    Skeleton.dispatch_request = dispatch_request
    Skeleton._awsbox_sqs_retention = True
    LOG.info("awsbox SQS MessageRetentionPeriod validation applied")


_patch()
