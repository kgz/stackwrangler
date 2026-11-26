"""Reject user-supplied ``aws:``-prefixed EC2 tag keys (#825).

Real AWS reserves the ``aws:`` prefix for services (CloudFormation,
Auto Scaling, …). CreateTags / DeleteTags / TagSpecifications from a
normal principal get InvalidParameterValue; LocalEmu's moto TagBackend
accepted them, so deploy-role ResourceTag conditions on
``aws:cloudformation:stack-name`` were forgeable.

CloudFormation resource providers set ``aws:cloudformation:*`` via the
same create APIs under the deploy role. While those providers run we
raise a thread-local allow flag so their TagSpecifications still land.
"""

from __future__ import annotations

import logging
import threading

LOG = logging.getLogger("localemu.awsbox.ec2_reserved_tag_keys")

_HANDLER_TAG = "awsbox.ec2_reserved_tag_keys"
_tls = threading.local()


def allow_aws_system_tags(enabled: bool = True) -> None:
    """CFN resource-provider path may set reserved keys for this thread."""
    _tls.allow = bool(enabled)


def _system_tags_allowed() -> bool:
    return bool(getattr(_tls, "allow", False))


def _normalize_tag_keys(raw: object) -> list[str]:
    from localemu.services.iam_enforcement.resource_tag_loader import (
        _normalize_tag_list,
    )

    if raw is None:
        return []
    if isinstance(raw, dict) and any(
        k in raw for k in ("Key", "key", "Tags", "tags")
    ):
        # Single Tag or TagSpecification-ish — normalize via list form.
        if "Tags" in raw or "tags" in raw:
            return list(_normalize_tag_list(raw.get("Tags") or raw.get("tags") or []).keys())
        return list(_normalize_tag_list([raw]).keys())
    if isinstance(raw, dict):
        # Flat {key: value} from some moto paths.
        return [str(k) for k in raw.keys()]
    if isinstance(raw, list):
        return list(_normalize_tag_list(raw).keys())
    return []


def _keys_from_request(params: dict) -> list[str]:
    keys: list[str] = []
    for field in ("Tags", "Tag"):
        keys.extend(_normalize_tag_keys(params.get(field)))
    specs = params.get("TagSpecifications") or params.get("TagSpecification") or []
    if isinstance(specs, dict):
        specs = [specs]
    if isinstance(specs, list):
        for spec in specs:
            if not isinstance(spec, dict):
                continue
            keys.extend(_normalize_tag_keys(spec.get("Tags") or spec.get("tags")))
    # Preserve order, drop dupes.
    seen: set[str] = set()
    out: list[str] = []
    for key in keys:
        if key not in seen:
            seen.add(key)
            out.append(key)
    return out


def _reserved_keys(keys: list[str]) -> list[str]:
    return [k for k in keys if isinstance(k, str) and k.lower().startswith("aws:")]


def _reject_message(key: str) -> str:
    return (
        f"Value ( {key} ) for parameter key is invalid. "
        "Tag keys starting with 'aws:' are reserved for internal use"
    )


def _raise_invalid(key: str) -> None:
    from localemu.aws.api import CommonServiceException

    raise CommonServiceException(
        code="InvalidParameterValue",
        message=_reject_message(key),
        status_code=400,
        sender_fault=True,
    )


class Ec2ReservedTagKeysHandler:
    """Request-chain: reject user ``aws:`` tag keys before IAM / dispatch."""

    _le_handler_tag = _HANDLER_TAG

    def __call__(self, chain, context, response) -> None:
        if getattr(context, "is_internal_call", False):
            return
        if _system_tags_allowed():
            return
        service = getattr(context, "service", None)
        operation = getattr(context, "operation", None)
        if service is None or operation is None:
            return
        if getattr(service, "service_name", None) != "ec2":
            return
        op = operation.name
        params = context.service_request or {}
        if not isinstance(params, dict):
            return

        check = False
        if op in ("CreateTags", "DeleteTags"):
            check = True
        elif op.startswith("Create") and op not in (
            "CreateDefaultVpc",
            "CreateDefaultSubnet",
        ):
            specs = params.get("TagSpecifications") or params.get("TagSpecification")
            check = bool(specs)
        if not check:
            return

        reserved = _reserved_keys(_keys_from_request(params))
        if not reserved:
            return
        # Even a single reserved key fails the whole call (AWS behaviour).
        _raise_invalid(reserved[0])


def _patch_cfn_executor() -> None:
    """Allow CFN resource providers to set ``aws:cloudformation:*`` tags."""
    try:
        from localemu.services.cloudformation.resource_provider import (
            ResourceProviderExecutor,
        )
    except Exception:
        LOG.debug("cfn resource provider unavailable; skip system-tag allow", exc_info=True)
        return

    if getattr(ResourceProviderExecutor.execute_action, "_awsbox_reserved_tags", False):
        return

    orig = ResourceProviderExecutor.execute_action

    def execute_action(self, resource_provider, raw_payload):
        allow_aws_system_tags(True)
        try:
            return orig(self, resource_provider, raw_payload)
        finally:
            allow_aws_system_tags(False)

    execute_action._awsbox_reserved_tags = True
    ResourceProviderExecutor.execute_action = execute_action
    LOG.info("awsbox CFN execute_action allows aws: system tags")


def _install() -> None:
    from localemu.aws.handlers import serve_custom_service_request_handlers

    req_handlers = serve_custom_service_request_handlers.handlers
    if not any(getattr(h, "_le_handler_tag", None) == _HANDLER_TAG for h in req_handlers):
        # Before IAM so forge attempts fail with InvalidParameterValue, not AccessDenied.
        req_handlers.insert(0, Ec2ReservedTagKeysHandler())

    _patch_cfn_executor()
    LOG.info("awsbox ec2 reserved aws: tag key rejection enabled")


_install()
