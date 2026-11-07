"""Map boto3 operation names to AWS IAM action names.

AWS deliberately uses non-1:1 mappings between API operations and IAM
actions. The most surprising offenders:

* ``lambda:Invoke``                           -> ``lambda:InvokeFunction``
* ``s3:ListObjects`` / ``s3:ListObjectsV2``   -> ``s3:ListBucket``
* ``s3:ListBuckets``                          -> ``s3:ListAllMyBuckets``
* ``s3:HeadBucket``                           -> ``s3:ListBucket``
* ``s3:HeadObject``                           -> ``s3:GetObject``
* ``kms:ReEncrypt`` requires BOTH ``kms:ReEncryptFrom`` AND ``kms:ReEncryptTo``
* All S3 multipart upload ops collapse to ``s3:PutObject``
* All SQS/SNS ``*Batch`` ops collapse to their non-batch action

Without this translator, a user with a policy granting the correct
IAM action gets a 403 because the enforcer is checking against a
non-existent permission like ``lambda:Invoke`` or ``s3:ListObjects``.

This map is intentionally narrow: the default ``service:OperationName``
mapping is correct for the vast majority of AWS actions, so we only
list the cases where AWS diverges. Pulled from the AWS Service
Authorization Reference (``s3``, ``lambda``, ``sqs``, ``sns``, ``kms``,
``dynamodb`` chapters):
https://docs.aws.amazon.com/service-authorization/latest/reference/
"""

from __future__ import annotations

# (service, operation_name) -> list of IAM action names that must all be allowed.
# When the right-hand list has multiple entries, the call requires ALL of them
# (e.g. CopyObject needs both GetObject on the source and PutObject on the dest).
ACTION_MAP: dict[tuple[str, str], list[str]] = {
    # ---- S3 ----
    ("s3", "ListBuckets"):        ["s3:ListAllMyBuckets"],
    ("s3", "ListObjects"):        ["s3:ListBucket"],
    ("s3", "ListObjectsV2"):      ["s3:ListBucket"],
    ("s3", "ListObjectVersions"): ["s3:ListBucketVersions"],
    ("s3", "HeadBucket"):         ["s3:ListBucket"],
    ("s3", "HeadObject"):         ["s3:GetObject"],
    ("s3", "CopyObject"):         ["s3:GetObject", "s3:PutObject"],
    ("s3", "GetBucketTagging"):   ["s3:GetBucketTagging"],
    ("s3", "PutBucketTagging"):   ["s3:PutBucketTagging"],
    ("s3", "GetBucketLocation"):  ["s3:GetBucketLocation"],
    # ---- S3 multipart upload (all gate on PutObject in real AWS) ----
    ("s3", "CreateMultipartUpload"):   ["s3:PutObject"],
    ("s3", "UploadPart"):              ["s3:PutObject"],
    ("s3", "UploadPartCopy"):          ["s3:PutObject", "s3:GetObject"],
    ("s3", "CompleteMultipartUpload"): ["s3:PutObject"],
    ("s3", "ListMultipartUploads"):    ["s3:ListBucketMultipartUploads"],
    ("s3", "ListParts"):               ["s3:ListMultipartUploadParts"],
    # ---- S3 object query / batch delete ----
    ("s3", "SelectObjectContent"):     ["s3:GetObject"],
    ("s3", "DeleteObjects"):           ["s3:DeleteObject"],
    # ---- S3 bucket-config name rewrites ----
    ("s3", "GetBucketEncryption"):     ["s3:GetEncryptionConfiguration"],
    ("s3", "PutBucketEncryption"):     ["s3:PutEncryptionConfiguration"],
    ("s3", "DeleteBucketEncryption"):  ["s3:PutEncryptionConfiguration"],
    ("s3", "GetBucketCors"):           ["s3:GetBucketCORS"],
    ("s3", "PutBucketCors"):           ["s3:PutBucketCORS"],
    ("s3", "DeleteBucketCors"):        ["s3:PutBucketCORS"],
    ("s3", "GetBucketReplication"):    ["s3:GetReplicationConfiguration"],
    ("s3", "PutBucketReplication"):    ["s3:PutReplicationConfiguration"],
    ("s3", "DeleteBucketReplication"): ["s3:PutReplicationConfiguration"],
    ("s3", "GetBucketLifecycle"):              ["s3:GetLifecycleConfiguration"],
    ("s3", "GetBucketLifecycleConfiguration"): ["s3:GetLifecycleConfiguration"],
    ("s3", "PutBucketLifecycle"):              ["s3:PutLifecycleConfiguration"],
    ("s3", "PutBucketLifecycleConfiguration"): ["s3:PutLifecycleConfiguration"],
    ("s3", "DeleteBucketLifecycle"):           ["s3:PutLifecycleConfiguration"],
    ("s3", "GetPublicAccessBlock"):    ["s3:GetBucketPublicAccessBlock"],
    ("s3", "PutPublicAccessBlock"):    ["s3:PutBucketPublicAccessBlock"],
    ("s3", "DeletePublicAccessBlock"): ["s3:PutBucketPublicAccessBlock"],
    # ---- Lambda: the wire op is Invoke but the IAM action is InvokeFunction ----
    ("lambda", "Invoke"):                   ["lambda:InvokeFunction"],
    ("lambda", "InvokeWithResponseStream"): ["lambda:InvokeFunction"],
    ("lambda", "InvokeAsync"):              ["lambda:InvokeFunction"],
    ("lambda", "GetLayerVersionByArn"):     ["lambda:GetLayerVersion"],
    # ---- SQS batch ops collapse to the non-batch action ----
    ("sqs", "SendMessageBatch"):             ["sqs:SendMessage"],
    ("sqs", "DeleteMessageBatch"):           ["sqs:DeleteMessage"],
    ("sqs", "ChangeMessageVisibilityBatch"): ["sqs:ChangeMessageVisibility"],
    # ---- SNS batch op ----
    ("sns", "PublishBatch"): ["sns:Publish"],
    # ---- KMS ReEncrypt requires BOTH halves ----
    ("kms", "ReEncrypt"): ["kms:ReEncryptFrom", "kms:ReEncryptTo"],
    # ---- DynamoDB transactions ----
    # TransactWriteItems is expanded per item by ``expand_permission_checks``
    # (Put/Update/Delete/ConditionCheck → matching action + table ARN). Kept
    # out of ACTION_MAP so a stale single-ARN path cannot demand all four.
    # TransactGetItems collapses to GetItem when the body is not inspected.
    ("dynamodb", "TransactGetItems"): ["dynamodb:GetItem"],
    # ---- EC2 ----
    # EC2 mostly matches 1:1, but Describe* is universal and Run* maps to RunInstances.
    # No overrides needed today; placeholder for future.
    # ---- IAM ----
    # IAM operations match 1:1 (CreateUser -> iam:CreateUser, etc.). No overrides.
    # ---- STS ----
    # STS operations match 1:1 (AssumeRole -> sts:AssumeRole, etc.).
    # ---- S3Control access points: the s3: namespace is what AWS uses for these IAM actions ----
    # The s3control wire service uses ``s3:`` IAM actions per AWS docs.
    # Without this map the enforcer asks for ``s3control:...`` which is
    # not a real IAM action ; a least-privilege policy written the
    # AWS-correct way (``s3:CreateAccessPoint``) would be wrongly denied.
    ("s3control", "CreateAccessPoint"):              ["s3:CreateAccessPoint"],
    ("s3control", "GetAccessPoint"):                 ["s3:GetAccessPoint"],
    ("s3control", "ListAccessPoints"):               ["s3:ListAccessPoints"],
    ("s3control", "DeleteAccessPoint"):              ["s3:DeleteAccessPoint"],
    ("s3control", "PutAccessPointPolicy"):           ["s3:PutAccessPointPolicy"],
    ("s3control", "GetAccessPointPolicy"):           ["s3:GetAccessPointPolicy"],
    ("s3control", "DeleteAccessPointPolicy"):        ["s3:DeleteAccessPointPolicy"],
    ("s3control", "GetAccessPointPolicyStatus"):     ["s3:GetAccessPointPolicyStatus"],
    ("s3control", "PutAccessPointConfigurationForObjectLambda"): [
        "s3:PutAccessPointConfigurationForObjectLambda",
    ],
    ("s3control", "GetAccessPointConfigurationForObjectLambda"): [
        "s3:GetAccessPointConfigurationForObjectLambda",
    ],
    # ---- S3Control Object Lambda access points ----
    ("s3control", "CreateAccessPointForObjectLambda"): [
        "s3:CreateAccessPointForObjectLambda",
    ],
    ("s3control", "GetAccessPointForObjectLambda"): [
        "s3:GetAccessPointForObjectLambda",
    ],
    ("s3control", "DeleteAccessPointForObjectLambda"): [
        "s3:DeleteAccessPointForObjectLambda",
    ],
    ("s3control", "PutAccessPointPolicyForObjectLambda"): [
        "s3:PutAccessPointPolicyForObjectLambda",
    ],
    ("s3control", "GetAccessPointPolicyForObjectLambda"): [
        "s3:GetAccessPointPolicyForObjectLambda",
    ],
    ("s3control", "DeleteAccessPointPolicyForObjectLambda"): [
        "s3:DeleteAccessPointPolicyForObjectLambda",
    ],
    ("s3control", "GetAccessPointPolicyStatusForObjectLambda"): [
        "s3:GetAccessPointPolicyStatusForObjectLambda",
    ],
    ("s3control", "ListAccessPointsForObjectLambda"): [
        "s3:ListAccessPointsForObjectLambda",
    ],
    # ---- S3Control Multi-Region Access Points ----
    ("s3control", "CreateMultiRegionAccessPoint"): [
        "s3:CreateMultiRegionAccessPoint",
    ],
    ("s3control", "DeleteMultiRegionAccessPoint"): [
        "s3:DeleteMultiRegionAccessPoint",
    ],
    ("s3control", "GetMultiRegionAccessPoint"): [
        "s3:GetMultiRegionAccessPoint",
    ],
    ("s3control", "ListMultiRegionAccessPoints"): [
        "s3:ListMultiRegionAccessPoints",
    ],
    ("s3control", "GetMultiRegionAccessPointPolicy"): [
        "s3:GetMultiRegionAccessPointPolicy",
    ],
    ("s3control", "PutMultiRegionAccessPointPolicy"): [
        "s3:PutMultiRegionAccessPointPolicy",
    ],
    ("s3control", "GetMultiRegionAccessPointPolicyStatus"): [
        "s3:GetMultiRegionAccessPointPolicyStatus",
    ],
    ("s3control", "GetMultiRegionAccessPointRoutes"): [
        "s3:GetMultiRegionAccessPointRoutes",
    ],
    ("s3control", "SubmitMultiRegionAccessPointRoutes"): [
        "s3:SubmitMultiRegionAccessPointRoutes",
    ],
    # ---- S3Control bucket-level Public Access Block + Storage Lens ----
    # Account-level PAB / Storage Lens / Outposts use the `s3:` namespace.
    ("s3control", "GetPublicAccessBlock"):    ["s3:GetAccountPublicAccessBlock"],
    ("s3control", "PutPublicAccessBlock"):    ["s3:PutAccountPublicAccessBlock"],
    ("s3control", "DeletePublicAccessBlock"): ["s3:PutAccountPublicAccessBlock"],
    ("s3control", "GetStorageLensConfiguration"): [
        "s3:GetStorageLensConfiguration",
    ],
    ("s3control", "PutStorageLensConfiguration"): [
        "s3:PutStorageLensConfiguration",
    ],
    ("s3control", "DeleteStorageLensConfiguration"): [
        "s3:DeleteStorageLensConfiguration",
    ],
    ("s3control", "ListStorageLensConfigurations"): [
        "s3:ListStorageLensConfigurations",
    ],
    ("s3control", "GetStorageLensConfigurationTagging"): [
        "s3:GetStorageLensConfigurationTagging",
    ],
    ("s3control", "PutStorageLensConfigurationTagging"): [
        "s3:PutStorageLensConfigurationTagging",
    ],
}


def map_action(service: str, operation_name: str) -> list[str]:
    """Translate an API operation to its IAM action name(s).

    Returns ``["{service}:{operation_name}"]`` (default 1:1) unless the
    pair is in ``ACTION_MAP``, in which case the mapped names are
    returned. The caller should treat the response as a list of actions
    that ALL must be authorised — for actions with multi-permission
    requirements (like CopyObject), enforcement is by intersection.
    """
    mapped = ACTION_MAP.get((service, operation_name))
    if mapped:
        return list(mapped)
    return [f"{service}:{operation_name}"]


# TransactWriteItems item key → IAM action (AWS evaluates only the ops used).
_DDB_TX_WRITE_ACTIONS = {
    "Put": "dynamodb:PutItem",
    "Update": "dynamodb:UpdateItem",
    "Delete": "dynamodb:DeleteItem",
    "ConditionCheck": "dynamodb:ConditionCheckItem",
}


def expand_permission_checks(
    service: str,
    operation_name: str,
    request_params: dict | None,
    region: str,
    account_id: str,
    build_resource_arn,
) -> list[tuple[str, str]]:
    """Return ``[(iam_action, resource_arn), ...]`` that must all be allowed.

    DynamoDB Transact* / Batch* have no top-level ``TableName``; a single
    ARN built from the request becomes ``table/*`` and never matches a
    table-scoped Allow (#306). Expand to per-item / per-table checks.
    Table/index ARNs go through ``build_resource_arn`` → ``_dynamodb_arn``.
    """
    params = request_params or {}

    def ddb_arn(table: object, index: object = None) -> str:
        name = table if isinstance(table, str) and table else "*"
        arn_params: dict = {"TableName": name}
        if isinstance(index, str) and index:
            arn_params["IndexName"] = index
        return build_resource_arn(
            "dynamodb", operation_name, arn_params, region, account_id
        )

    if service == "dynamodb" and operation_name == "TransactWriteItems":
        checks: list[tuple[str, str]] = []
        for entry in params.get("TransactItems") or []:
            if not isinstance(entry, dict):
                continue
            for key, action in _DDB_TX_WRITE_ACTIONS.items():
                body = entry.get(key)
                if not isinstance(body, dict):
                    continue
                checks.append((action, ddb_arn(body.get("TableName"))))
                break
        return checks

    if service == "dynamodb" and operation_name == "TransactGetItems":
        checks = []
        for entry in params.get("TransactItems") or []:
            if not isinstance(entry, dict):
                continue
            body = entry.get("Get")
            if not isinstance(body, dict):
                continue
            checks.append(("dynamodb:GetItem", ddb_arn(body.get("TableName"))))
        return checks

    if service == "dynamodb" and operation_name == "BatchWriteItem":
        request_items = params.get("RequestItems") or {}
        if isinstance(request_items, dict):
            return [
                ("dynamodb:BatchWriteItem", ddb_arn(table))
                for table in request_items
            ]
        return []

    if service == "dynamodb" and operation_name == "BatchGetItem":
        request_items = params.get("RequestItems") or {}
        if not isinstance(request_items, dict):
            return []
        checks = []
        for table, spec in request_items.items():
            # BatchGetItem is table-scoped; IndexName on an entry (non-AWS)
            # still goes through _dynamodb_arn like Query.
            index = spec.get("IndexName") if isinstance(spec, dict) else None
            checks.append(("dynamodb:BatchGetItem", ddb_arn(table, index)))
        return checks

    actions = map_action(service, operation_name)
    arn = build_resource_arn(
        service, operation_name, params, region, account_id
    )
    return [(action, arn) for action in actions]
