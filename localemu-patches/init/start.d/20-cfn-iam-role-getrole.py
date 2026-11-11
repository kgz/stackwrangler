"""AWS::IAM::Role create probes iam:GetRole before CreateRole (#679).

Real AWS CFN authorises a role that does not exist yet against ``role/<name>``
(no Path). Path-scoped ``CreateRole`` grants alone are therefore not enough —
deploy roles also need a pathless grant for GetRole / DeleteRolePolicy / ….
"""

from __future__ import annotations

import logging

from botocore.exceptions import ClientError

LOG = logging.getLogger("localemu.awsbox.cfn_iam_role_getrole")


def _patch() -> None:
    import localemu.services.cloudformation.provider_utils as util
    from localemu.services.iam.resource_providers.aws_iam_role import IAMRoleProvider

    _orig_create = IAMRoleProvider.create

    def create(self, request):
        model = request.desired_state
        role_name = model.get("RoleName")
        if not role_name:
            role_name = util.generate_default_name(
                request.stack_name, request.logical_resource_id
            )
            model["RoleName"] = role_name
        try:
            request.aws_client_factory.iam.get_role(RoleName=role_name)
        except ClientError as e:
            code = (e.response.get("Error") or {}).get("Code") or ""
            if code in ("NoSuchEntity", "NoSuchEntityException"):
                pass
            else:
                raise
        return _orig_create(self, request)

    IAMRoleProvider.create = create
    LOG.info("cfn IAM::Role: GetRole before CreateRole (#679)")


_patch()
