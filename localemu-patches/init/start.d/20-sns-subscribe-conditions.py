"""Populate sns:Protocol / sns:Endpoint on Subscribe IAM evaluation (#518).

Stock LocalEmu ``_build_conditions`` never sets these request keys, so an
identity policy that Allows ``sns:Subscribe`` only for a given protocol and
endpoint always denies. AWS documents both keys on Subscribe (topic resource).
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.sns_subscribe_conditions")


def _patch_build_conditions() -> None:
    from localemu.services.iam_enforcement import enforcer as enforcer_mod

    original = enforcer_mod._build_conditions

    def _build_conditions(context, caller):
        conditions = original(context, caller)
        service = getattr(getattr(context, "service", None), "service_name", None)
        operation = getattr(getattr(context, "operation", None), "name", None)
        if service != "sns" or operation != "Subscribe":
            return conditions
        params = context.service_request or {}
        protocol = params.get("Protocol")
        if protocol is None:
            protocol = params.get("protocol")
        endpoint = params.get("Endpoint")
        if endpoint is None:
            endpoint = params.get("endpoint")
        if protocol is not None and protocol != "":
            conditions["sns:Protocol"] = str(protocol)
        if endpoint is not None and endpoint != "":
            conditions["sns:Endpoint"] = str(endpoint)
        return conditions

    enforcer_mod._build_conditions = _build_conditions
    LOG.info("awsbox SNS Subscribe sns:Protocol / sns:Endpoint condition keys wired")


_patch_build_conditions()
