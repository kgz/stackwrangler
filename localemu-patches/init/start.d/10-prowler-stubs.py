"""Stub Prowler-missing EC2/IAM actions with empty/default AWS-shaped responses."""

from __future__ import annotations

import logging
import uuid

LOG = logging.getLogger("localemu.awsbox.prowler_stubs")


def _patch_ec2() -> None:
    from localemu.services.ec2.provider import Ec2Provider

    def get_image_block_public_access_state(self, context, dry_run=None, **kwargs):
        del self, context, dry_run, kwargs
        return {"ImageBlockPublicAccessState": "unblocked"}

    def get_instance_metadata_defaults(self, context, dry_run=None, **kwargs):
        del self, context, dry_run, kwargs
        return {
            "AccountLevel": {
                "HttpTokens": "optional",
                "HttpPutResponseHopLimit": 1,
                "HttpEndpoint": "enabled",
                "InstanceMetadataTags": "disabled",
            }
        }

    def describe_client_vpn_endpoints(
        self,
        context,
        client_vpn_endpoint_ids=None,
        filters=None,
        max_results=None,
        next_token=None,
        dry_run=None,
        **kwargs,
    ):
        del (
            self,
            context,
            client_vpn_endpoint_ids,
            filters,
            max_results,
            next_token,
            dry_run,
            kwargs,
        )
        return {"ClientVpnEndpoints": []}

    Ec2Provider.get_image_block_public_access_state = get_image_block_public_access_state
    Ec2Provider.get_instance_metadata_defaults = get_instance_metadata_defaults
    Ec2Provider.describe_client_vpn_endpoints = describe_client_vpn_endpoints


def _patch_iam() -> None:
    from localemu.services.iam.provider import IamProvider

    def generate_service_last_accessed_details(
        self, context, arn, granularity=None, **kwargs
    ):
        del self, context, arn, granularity, kwargs
        return {"JobId": uuid.uuid4().hex}

    def list_organizations_features(self, context, **kwargs):
        del self, context, kwargs
        return {"EnabledFeatures": []}

    IamProvider.generate_service_last_accessed_details = (
        generate_service_last_accessed_details
    )
    IamProvider.list_organizations_features = list_organizations_features


def _patch_rds_moto() -> None:
    from moto.core.responses import ActionResult
    from moto.rds.responses import RDSResponse

    def describe_db_engine_versions(self):
        del self
        return ActionResult({"DBEngineVersions": []})

    RDSResponse.describe_db_engine_versions = describe_db_engine_versions


def _patch_ssm_moto() -> None:
    from moto.core.responses import ActionResult
    from moto.ssm.responses import SimpleSystemManagerResponse

    def list_resource_compliance_summaries(self):
        del self
        return ActionResult({"ResourceComplianceSummaryItems": []})

    SimpleSystemManagerResponse.list_resource_compliance_summaries = (
        list_resource_compliance_summaries
    )


def _patch_backup_report_plans() -> None:
    """Empty ListReportPlans — moto has no /audit/report-plans route."""
    import json

    from moto.backup import urls as backup_urls
    from moto.backup.responses import BackupResponse

    def list_report_plans(self):
        del self
        return json.dumps({"ReportPlans": []})

    BackupResponse.list_report_plans = list_report_plans
    backup_urls.url_paths.setdefault(
        "{0}/audit/report-plans/?$", backup_urls.response.dispatch
    )


_patch_ec2()
_patch_iam()
_patch_rds_moto()
_patch_ssm_moto()
_patch_backup_report_plans()
LOG.info("awsbox prowler stubs applied (ec2 + iam + rds + ssm + backup)")
