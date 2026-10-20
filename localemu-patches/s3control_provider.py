"""S3 Control provider with Prowler-needed account reads (#196).

Extends LocalEmu's tagging-only S3ControlProvider with moto-backed
GetPublicAccessBlock / ListAccessPoints / ListMultiRegionAccessPoints.
Mounted over the image file at container start.
"""

from __future__ import annotations

from localemu.aws.api import RequestContext
from localemu.aws.api.s3control import (
    AccountId,
    BucketName,
    GetPublicAccessBlockOutput,
    ListAccessPointsResult,
    ListMultiRegionAccessPointsResult,
    ListTagsForResourceResult,
    MaxResults,
    NonEmptyMaxLength1024String,
    PublicAccessBlockConfiguration,
    S3ControlApi,
    S3ResourceArn,
    Tag,
    TagKeyList,
    TagList,
    TagResourceResult,
    UntagResourceResult,
)
from localemu.services.s3.models import S3Store, s3_stores
from localemu.services.s3control.validation import validate_arn_for_tagging, validate_tags
from localemu.state import StateVisitor


def _s3control_backend(account_id: str, region: str):
    from moto.s3control.models import s3control_backends

    # S3 Control is account-global in moto (`aws` partition key), not per-region.
    account_backends = s3control_backends[account_id]
    if "aws" in account_backends:
        return account_backends["aws"]
    if region in account_backends:
        return account_backends[region]
    return account_backends[next(iter(account_backends))]


def _default_public_access_block() -> PublicAccessBlockConfiguration:
    return PublicAccessBlockConfiguration(
        BlockPublicAcls=False,
        IgnorePublicAcls=False,
        BlockPublicPolicy=False,
        RestrictPublicBuckets=False,
    )


class S3ControlProvider(S3ControlApi):
    def accept_state_visitor(self, visitor: StateVisitor):
        from moto.s3control.models import s3control_backends

        visitor.visit(s3control_backends)

    @staticmethod
    def get_s3_store(account_id: str, region: str) -> S3Store:
        return s3_stores[account_id][region]

    def tag_resource(
        self,
        context: RequestContext,
        account_id: AccountId,
        resource_arn: S3ResourceArn,
        tags: TagList,
        **kwargs,
    ) -> TagResourceResult:
        validate_arn_for_tagging(resource_arn, context.partition, account_id, context.region)
        validate_tags(tags)

        store = self.get_s3_store(account_id, context.region)
        store.tags.update_tags(resource_arn, {tag["Key"]: tag["Value"] for tag in tags})
        return TagResourceResult()

    def untag_resource(
        self,
        context: RequestContext,
        account_id: AccountId,
        resource_arn: S3ResourceArn,
        tag_keys: TagKeyList,
        **kwargs,
    ) -> UntagResourceResult:
        validate_arn_for_tagging(resource_arn, context.partition, account_id, context.region)

        store = self.get_s3_store(account_id, context.region)
        store.tags.delete_tags(resource_arn, tag_keys)
        return UntagResourceResult()

    def list_tags_for_resource(
        self, context: RequestContext, account_id: AccountId, resource_arn: S3ResourceArn, **kwargs
    ) -> ListTagsForResourceResult:
        validate_arn_for_tagging(resource_arn, context.partition, account_id, context.region)

        store = self.get_s3_store(account_id, context.region)
        tags = store.tags.get_tags(resource_arn)
        return ListTagsForResourceResult(
            Tags=[Tag(Key=key, Value=value) for key, value in tags.items()]
        )

    def get_public_access_block(
        self, context: RequestContext, account_id: AccountId, **kwargs
    ) -> GetPublicAccessBlockOutput:
        backend = _s3control_backend(account_id, context.region)
        block = backend.public_access_block
        if block is None:
            return GetPublicAccessBlockOutput(
                PublicAccessBlockConfiguration=_default_public_access_block()
            )
        return GetPublicAccessBlockOutput(
            PublicAccessBlockConfiguration=PublicAccessBlockConfiguration(
                BlockPublicAcls=block.block_public_acls,
                IgnorePublicAcls=block.ignore_public_acls,
                BlockPublicPolicy=block.block_public_policy,
                RestrictPublicBuckets=block.restrict_public_buckets,
            )
        )

    def list_access_points(
        self,
        context: RequestContext,
        account_id: AccountId,
        bucket: BucketName | None = None,
        next_token: NonEmptyMaxLength1024String | None = None,
        max_results: MaxResults | None = None,
        data_source_id=None,
        data_source_type=None,
        **kwargs,
    ) -> ListAccessPointsResult:
        del next_token, max_results, data_source_id, data_source_type
        backend = _s3control_backend(account_id, context.region)
        points = list(backend.access_points.get(account_id, {}).values())
        if bucket:
            points = [ap for ap in points if ap.bucket == bucket]
        return ListAccessPointsResult(
            AccessPointList=[
                {
                    "Name": ap.name,
                    "NetworkOrigin": ap.network_origin,
                    "Bucket": ap.bucket,
                    "AccessPointArn": ap.arn,
                    "Alias": ap.alias,
                    **(
                        {"VpcConfiguration": {"VpcId": ap.vpc_id}}
                        if ap.vpc_id
                        else {}
                    ),
                }
                for ap in points
            ]
        )

    def list_multi_region_access_points(
        self,
        context: RequestContext,
        account_id: AccountId,
        next_token: NonEmptyMaxLength1024String | None = None,
        max_results: MaxResults | None = None,
        **kwargs,
    ) -> ListMultiRegionAccessPointsResult:
        del next_token, max_results
        backend = _s3control_backend(account_id, context.region)
        mraps = list(backend.multi_region_access_points.get(account_id, {}).values())
        return ListMultiRegionAccessPointsResult(
            AccessPoints=[mrap.to_dict() for mrap in mraps]
        )
