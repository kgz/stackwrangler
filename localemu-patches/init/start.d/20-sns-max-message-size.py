"""Honour SNS topic attribute MaximumMessageSize (1024–1 048 576) on Publish (#373).

LocalEmu hard-codes 256 KiB. Real AWS defaults to 256 KiB and allows opt-in up to
1 MiB via MaximumMessageSize on CreateTopic / SetTopicAttributes.

Publish size uses a ContextVar-backed limit object so concurrent requests with
different topic caps do not clobber a process-global MAXIMUM_MESSAGE_LENGTH.

Topics with MaximumMessageSize > 256 KiB only allow firehose / sqs / lambda
subscriptions (≤100) — AWS large-message payload rules (#387).
"""

from __future__ import annotations

import contextvars
import logging

LOG = logging.getLogger("localemu.awsbox.sns_max_message_size")

_ATTR = "MaximumMessageSize"
_DEFAULT = 262_144  # 256 KiB
_MIN = 1_024
_MAX = 1_048_576  # 1 MiB
_LARGE_TOPIC_PROTOCOLS = frozenset({"sqs", "lambda", "firehose"})
_LARGE_TOPIC_SUB_LIMIT = 100

_limit_var: contextvars.ContextVar[int] = contextvars.ContextVar(
    "awsbox_sns_maximum_message_length",
    default=_DEFAULT,
)


class _MessageLengthLimit:
    """Compares as the per-request limit from ``_limit_var`` (no global swap)."""

    def _value(self) -> int:
        return _limit_var.get()

    def __index__(self) -> int:
        return self._value()

    def __int__(self) -> int:
        return self._value()

    def __repr__(self) -> str:
        return str(self._value())

    def __eq__(self, other):
        try:
            return self._value() == int(other)
        except (TypeError, ValueError):
            return NotImplemented

    def __lt__(self, other):
        try:
            return self._value() < int(other)
        except (TypeError, ValueError):
            return NotImplemented

    def __le__(self, other):
        try:
            return self._value() <= int(other)
        except (TypeError, ValueError):
            return NotImplemented

    def __gt__(self, other):
        try:
            return self._value() > int(other)
        except (TypeError, ValueError):
            return NotImplemented

    def __ge__(self, other):
        try:
            return self._value() >= int(other)
        except (TypeError, ValueError):
            return NotImplemented


def _parse_maximum_message_size(raw) -> int:
    from localemu.aws.api.sns import InvalidParameterException

    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise InvalidParameterException(
            f"Invalid parameter: Attributes Reason: Invalid value for attribute {_ATTR}"
        )
    if value < _MIN or value > _MAX:
        raise InvalidParameterException(
            f"Invalid parameter: Attributes Reason: Invalid value for attribute {_ATTR}"
        )
    return value


def _topic_limit(topic: dict | None) -> int:
    if not topic:
        return _DEFAULT
    attrs = topic.get("attributes") or {}
    raw = attrs.get(_ATTR)
    if raw is None:
        return _DEFAULT
    try:
        return _parse_maximum_message_size(raw)
    except Exception:
        return _DEFAULT


def _try_topic_limit(provider, context, topic_arn, target_arn) -> int:
    """Resolve topic limit without failing the request early (size check precedes NotFound)."""
    topic_or_target = topic_arn or target_arn
    if not topic_or_target or ":endpoint/" in topic_or_target:
        return _DEFAULT
    try:
        return _topic_limit(provider._get_topic(topic_or_target, context))
    except Exception:
        return _DEFAULT


def _subscription_store(provider, topic_arn, context):
    from localemu.services.sns.utils import parse_and_validate_topic_arn

    parsed = parse_and_validate_topic_arn(topic_arn)
    return provider.get_store(parsed["account"], parsed["region"])


def _topic_subscription_protocols(provider, topic, context, topic_arn) -> list[str]:
    store = _subscription_store(provider, topic_arn, context)
    protocols: list[str] = []
    for sub_arn in topic.get("subscriptions") or []:
        sub = store.subscriptions.get(sub_arn) or {}
        proto = sub.get("Protocol")
        if proto:
            protocols.append(proto)
    return protocols


def _raise_if_large_topic_subs_invalid(protocols: list[str]) -> None:
    from localemu.aws.api.sns import InvalidParameterException

    if len(protocols) > _LARGE_TOPIC_SUB_LIMIT:
        raise InvalidParameterException(
            "Invalid parameter: Attributes Reason: Topics with MaximumMessageSize "
            f"greater than {_DEFAULT} cannot have more than {_LARGE_TOPIC_SUB_LIMIT} subscriptions"
        )
    bad = sorted({p for p in protocols if p not in _LARGE_TOPIC_PROTOCOLS})
    if bad:
        raise InvalidParameterException(
            "Invalid parameter: Attributes Reason: Topics with MaximumMessageSize "
            f"greater than {_DEFAULT} only support SQS, Lambda, and Firehose subscriptions"
        )


def _raise_if_subscribe_disallowed(provider, context, topic_arn, protocol, endpoint) -> None:
    from localemu.aws.api.sns import InvalidParameterException

    topic = provider._get_topic(topic_arn, context)
    if _topic_limit(topic) <= _DEFAULT:
        return

    if protocol not in _LARGE_TOPIC_PROTOCOLS:
        raise InvalidParameterException(
            "Invalid parameter: Protocol Reason: Topics with MaximumMessageSize "
            f"greater than {_DEFAULT} only support SQS, Lambda, and Firehose subscriptions"
        )

    store = _subscription_store(provider, topic_arn, context)
    topic_subscriptions = topic.get("subscriptions") or []
    for sub_arn in topic_subscriptions:
        sub = store.subscriptions.get(sub_arn) or {}
        if sub.get("Endpoint") == endpoint:
            # Idempotent re-subscribe; stock handler decides attributes mismatch.
            return

    if len(topic_subscriptions) >= _LARGE_TOPIC_SUB_LIMIT:
        raise InvalidParameterException(
            "Invalid parameter: TopicArn Reason: Topics with MaximumMessageSize "
            f"greater than {_DEFAULT} cannot have more than {_LARGE_TOPIC_SUB_LIMIT} subscriptions"
        )


def _patch() -> None:
    import localemu.services.sns.provider as sns_provider
    from localemu.services.sns.provider import SnsProvider

    if getattr(SnsProvider, "_awsbox_sns_max_message_size", False):
        return

    # One-time install: publish does `size > MAXIMUM_MESSAGE_LENGTH` against this object.
    sns_provider.MAXIMUM_MESSAGE_LENGTH = _MessageLengthLimit()

    orig_create = SnsProvider.create_topic
    orig_set = SnsProvider.set_topic_attributes
    orig_subscribe = SnsProvider.subscribe
    orig_publish = SnsProvider.publish
    orig_publish_batch = SnsProvider.publish_batch

    def create_topic(self, context, name, attributes=None, tags=None, data_protection_policy=None, **kwargs):
        if attributes and _ATTR in attributes:
            parsed = _parse_maximum_message_size(attributes[_ATTR])
            attributes = dict(attributes)
            attributes[_ATTR] = str(parsed)
        return orig_create(
            self,
            context,
            name,
            attributes=attributes,
            tags=tags,
            data_protection_policy=data_protection_policy,
            **kwargs,
        )

    def set_topic_attributes(self, context, topic_arn, attribute_name, attribute_value=None, **kwargs):
        if attribute_name == _ATTR:
            parsed = _parse_maximum_message_size(attribute_value)
            attribute_value = str(parsed)
            if parsed > _DEFAULT:
                topic = self._get_topic(topic_arn, context)
                protocols = _topic_subscription_protocols(self, topic, context, topic_arn)
                _raise_if_large_topic_subs_invalid(protocols)
        return orig_set(
            self,
            context,
            topic_arn,
            attribute_name,
            attribute_value=attribute_value,
            **kwargs,
        )

    def subscribe(
        self,
        context,
        topic_arn,
        protocol,
        endpoint=None,
        attributes=None,
        return_subscription_arn=None,
        **kwargs,
    ):
        _raise_if_subscribe_disallowed(self, context, topic_arn, protocol, endpoint)
        return orig_subscribe(
            self,
            context,
            topic_arn,
            protocol,
            endpoint=endpoint,
            attributes=attributes,
            return_subscription_arn=return_subscription_arn,
            **kwargs,
        )

    def publish(
        self,
        context,
        message,
        topic_arn=None,
        target_arn=None,
        phone_number=None,
        subject=None,
        message_structure=None,
        message_attributes=None,
        message_deduplication_id=None,
        message_group_id=None,
        **kwargs,
    ):
        token = _limit_var.set(_try_topic_limit(self, context, topic_arn, target_arn))
        try:
            return orig_publish(
                self,
                context,
                message,
                topic_arn=topic_arn,
                target_arn=target_arn,
                phone_number=phone_number,
                subject=subject,
                message_structure=message_structure,
                message_attributes=message_attributes,
                message_deduplication_id=message_deduplication_id,
                message_group_id=message_group_id,
                **kwargs,
            )
        finally:
            _limit_var.reset(token)

    def publish_batch(self, context, topic_arn, publish_batch_request_entries, **kwargs):
        try:
            limit = _topic_limit(self._get_topic(topic_arn, context))
        except Exception:
            limit = _DEFAULT
        token = _limit_var.set(limit)
        try:
            return orig_publish_batch(
                self,
                context,
                topic_arn,
                publish_batch_request_entries,
                **kwargs,
            )
        finally:
            _limit_var.reset(token)

    SnsProvider.create_topic = create_topic
    SnsProvider.set_topic_attributes = set_topic_attributes
    SnsProvider.subscribe = subscribe
    SnsProvider.publish = publish
    SnsProvider.publish_batch = publish_batch
    SnsProvider._awsbox_sns_max_message_size = True
    LOG.info("awsbox SNS MaximumMessageSize + large-topic subscribe limits applied")


_patch()
