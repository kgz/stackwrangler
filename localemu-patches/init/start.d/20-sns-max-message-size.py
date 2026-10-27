"""Honour SNS topic attribute MaximumMessageSize (1024–1 048 576) on Publish (#373).

LocalEmu hard-codes 256 KiB. Real AWS defaults to 256 KiB and allows opt-in up to
1 MiB via MaximumMessageSize on CreateTopic / SetTopicAttributes.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.sns_max_message_size")

_ATTR = "MaximumMessageSize"
_DEFAULT = 262_144  # 256 KiB
_MIN = 1_024
_MAX = 1_048_576  # 1 MiB


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


def _resolve_topic(provider, context, topic_arn, target_arn):
    topic_or_target = topic_arn or target_arn
    if not topic_or_target:
        return None
    if ":endpoint/" in topic_or_target:
        return None
    return provider._get_topic(topic_or_target, context)


def _patch() -> None:
    import localemu.services.sns.provider as sns_provider
    from localemu.services.sns.provider import SnsProvider

    if getattr(SnsProvider, "_awsbox_sns_max_message_size", False):
        return

    orig_create = SnsProvider.create_topic
    orig_set = SnsProvider.set_topic_attributes
    orig_publish = SnsProvider.publish
    orig_publish_batch = SnsProvider.publish_batch

    def create_topic(self, context, name, attributes=None, tags=None, data_protection_policy=None, **kwargs):
        if attributes and _ATTR in attributes:
            # store as string like other SNS topic attrs
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
        return orig_set(
            self,
            context,
            topic_arn,
            attribute_name,
            attribute_value=attribute_value,
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
        topic = _resolve_topic(self, context, topic_arn, target_arn)
        limit = _topic_limit(topic)
        old = sns_provider.MAXIMUM_MESSAGE_LENGTH
        sns_provider.MAXIMUM_MESSAGE_LENGTH = limit
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
            sns_provider.MAXIMUM_MESSAGE_LENGTH = old

    def publish_batch(self, context, topic_arn, publish_batch_request_entries, **kwargs):
        topic = self._get_topic(topic_arn, context)
        limit = _topic_limit(topic)
        old = sns_provider.MAXIMUM_MESSAGE_LENGTH
        sns_provider.MAXIMUM_MESSAGE_LENGTH = limit
        try:
            return orig_publish_batch(
                self,
                context,
                topic_arn,
                publish_batch_request_entries,
                **kwargs,
            )
        finally:
            sns_provider.MAXIMUM_MESSAGE_LENGTH = old

    SnsProvider.create_topic = create_topic
    SnsProvider.set_topic_attributes = set_topic_attributes
    SnsProvider.publish = publish
    SnsProvider.publish_batch = publish_batch
    SnsProvider._awsbox_sns_max_message_size = True
    LOG.info("awsbox SNS MaximumMessageSize applied")


_patch()
