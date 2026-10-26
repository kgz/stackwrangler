"""Add wafv2 ListResourcesForWebACL (moto stores associations but omits the list op)."""

from __future__ import annotations

import json
import logging
from typing import Any, Optional

LOG = logging.getLogger("localemu.awsbox.wafv2")


def _patch() -> None:
    from moto.core.common_types import TYPE_RESPONSE
    from moto.wafv2.models import WAFV2Backend
    from moto.wafv2.responses import WAFV2Response

    def list_resources_for_web_acl(
        self: WAFV2Backend,
        web_acl_arn: str,
        resource_type: Optional[str] = None,
    ) -> list[str]:
        del resource_type
        web_acl = self.wacls.get(web_acl_arn)
        if not web_acl:
            return []
        return list(web_acl.associated_resources)

    def list_resources_for_web_acl_response(self: WAFV2Response) -> TYPE_RESPONSE:
        body = json.loads(self.body)
        web_acl_arn = body["WebACLArn"]
        resource_type = body.get("ResourceType")
        arns = self.wafv2_backend.list_resources_for_web_acl(web_acl_arn, resource_type)
        payload: dict[str, Any] = {"ResourceArns": arns}
        return 200, {"Content-Type": "application/json"}, json.dumps(payload)

    WAFV2Backend.list_resources_for_web_acl = list_resources_for_web_acl
    WAFV2Response.list_resources_for_web_acl = list_resources_for_web_acl_response
    LOG.info("awsbox wafv2 ListResourcesForWebACL patch applied")


_patch()
