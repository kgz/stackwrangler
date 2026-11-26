"""Reject user-supplied ``aws:``-prefixed EC2 tag keys (#825).

Real AWS reserves the ``aws:`` prefix for services (CloudFormation,
Auto Scaling, …). CreateTags / DeleteTags / TagSpecifications from a
normal principal get InvalidParameterValue; LocalEmu's moto TagBackend
accepted them, so deploy-role ResourceTag conditions on
``aws:cloudformation:stack-name`` were forgeable.

Must run **before** IAM so forge attempts get InvalidParameterValue
(not AccessDenied). We wrap ``IAMEnforcementHandler.__call__`` rather
than ``serve_custom_service_request_handlers`` (that composite sits
*after* IAM in ``aws/app.py``).

CloudFormation resource providers set ``aws:cloudformation:*`` via the
same create APIs under the deploy role. While those providers run we
raise a thread-local allow flag so their TagSpecifications still land.
"""

from __future__ import annotations

import logging
import threading

LOG = logging.getLogger("localemu.awsbox.ec2_reserved_tag_keys")

_tls = threading.local()
_CFN_SYSTEM_TAG_HEADER = "x-localemu-cfn-system-tags"


def allow_aws_system_tags(enabled: bool = True) -> None:
    """CFN resource-provider path may set reserved keys for this thread."""
    _tls.allow = bool(enabled)


def _system_tags_allowed(context=None) -> bool:
    if bool(getattr(_tls, "allow", False)):
        return True
    if context is None:
        return False
    request = getattr(context, "request", None)
    headers = getattr(request, "headers", None)
    if headers is None:
        return False
    try:
        value = headers.get(_CFN_SYSTEM_TAG_HEADER) or headers.get(
            _CFN_SYSTEM_TAG_HEADER.title()
        )
    except Exception:
        return False
    return str(value or "").strip() in ("1", "true", "True")


def _normalize_tag_keys(raw: object) -> list[str]:
    from localemu.services.iam_enforcement.resource_tag_loader import (
        _normalize_tag_list,
    )

    if raw is None:
        return []
    if isinstance(raw, dict) and any(
        k in raw for k in ("Key", "key", "Tags", "tags")
    ):
        if "Tags" in raw or "tags" in raw:
            return list(
                _normalize_tag_list(raw.get("Tags") or raw.get("tags") or []).keys()
            )
        return list(_normalize_tag_list([raw]).keys())
    if isinstance(raw, dict):
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


def _check_reserved_tag_keys(context) -> None:
    if getattr(context, "is_internal_call", False):
        return
    if _system_tags_allowed(context):
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
    else:
        # Any op that accepts TagSpecifications (Create*, RunInstances, …).
        specs = params.get("TagSpecifications") or params.get("TagSpecification")
        check = bool(specs)
    if not check:
        return

    reserved = _reserved_keys(_keys_from_request(params))
    if not reserved:
        return
    _raise_invalid(reserved[0])


def _patch_before_iam() -> None:
    from localemu.services.iam_enforcement.enforcer import IAMEnforcementHandler

    if getattr(IAMEnforcementHandler, "_awsbox_ec2_reserved_tag_keys", False):
        return

    orig = IAMEnforcementHandler.__call__

    def __call__(self, chain, context, response):
        _check_reserved_tag_keys(context)
        return orig(self, chain, context, response)

    IAMEnforcementHandler.__call__ = __call__
    IAMEnforcementHandler._awsbox_ec2_reserved_tag_keys = True
    LOG.info("awsbox ec2 reserved aws: tag check wrapped before IAM")


def _patch_cfn_executor() -> None:
    """Allow CFN resource providers to set ``aws:cloudformation:*`` tags.

    Deploy runs on worker threads and GatewayShortCircuit may hop threads, so
    thread-locals alone are not enough. Stamp a request header on CFN clients
    and also set the TLS flag around ``execute_action`` for same-thread paths.
    """
    try:
        from localemu.services.cloudformation.resource_provider import (
            ResourceProviderExecutor,
        )
        from localemu.services.cloudformation import resource_provider as rp
    except Exception:
        LOG.debug(
            "cfn resource provider unavailable; skip system-tag allow",
            exc_info=True,
        )
        return

    if not getattr(ResourceProviderExecutor.execute_action, "_awsbox_reserved_tags", False):
        orig = ResourceProviderExecutor.execute_action

        def execute_action(self, resource_provider, raw_payload):
            allow_aws_system_tags(True)
            try:
                return orig(self, resource_provider, raw_payload)
            finally:
                allow_aws_system_tags(False)

        execute_action._awsbox_reserved_tags = True
        ResourceProviderExecutor.execute_action = execute_action

    factory = getattr(rp, "_cfn_resource_client_factory", None)
    if factory is not None and not getattr(factory, "_awsbox_reserved_tag_header", False):
        orig_hook = getattr(factory, "_get_client_post_hook", None)

        def _stamp_header(request, **_kwargs):
            try:
                request.headers[_CFN_SYSTEM_TAG_HEADER] = "1"
            except Exception:
                pass

        def _get_client_post_hook(self, client):
            if callable(orig_hook):
                client = orig_hook(client)
            try:
                client.meta.events.register("before-send.*.*", _stamp_header)
            except Exception:
                LOG.debug("cfn client header stamp failed", exc_info=True)
            return client

        factory._get_client_post_hook = _get_client_post_hook.__get__(
            factory, factory.__class__
        )
        factory._awsbox_reserved_tag_header = True

    LOG.info("awsbox CFN allows aws: system tags (TLS + request header)")


def _install() -> None:
    _patch_before_iam()
    _patch_cfn_executor()
    LOG.info("awsbox ec2 reserved aws: tag key rejection enabled")


_install()
