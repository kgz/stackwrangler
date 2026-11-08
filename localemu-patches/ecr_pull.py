"""Shared ECR URI rewrite + BatchGetImage authz (#211 / #219).

Mounted at ``/opt/awsbox/ecr/awsbox_ecr_pull.py``. ECS task_manager and the
Lambda start.d patch add that directory to ``sys.path`` and
``import awsbox_ecr_pull``.
"""

from __future__ import annotations

import os
import re

# <account>.dkr.ecr.<region>.amazonaws.com/<repo>[:tag|@digest]
ECR_IMAGE_RE = re.compile(
    r"^(?P<account>\d+)\.dkr\.ecr\.(?P<region>[a-z0-9-]+)\.amazonaws\.com/(?P<ref>.+)$"
)


def ecr_local_ref(ref: str) -> str:
    registry = os.environ.get("AWSBOX_ECR_REGISTRY", "127.0.0.1:5000").strip().rstrip("/")
    return f"{registry}/{ref}"


def ecr_image_id(ref: str) -> tuple[str, dict]:
    if "@" in ref:
        name, digest = ref.split("@", 1)
        return name, {"imageDigest": digest}
    if ":" in ref:
        name, tag = ref.rsplit(":", 1)
        return name, {"imageTag": tag}
    return ref, {"imageTag": "latest"}


def is_access_denied(exc: BaseException) -> bool:
    code = ""
    message = str(exc)
    response = getattr(exc, "response", None)
    if isinstance(response, dict):
        err = response.get("Error") or {}
        if isinstance(err, dict):
            code = str(err.get("Code") or "")
            message = str(err.get("Message") or message)
    blob = f"{code} {message}".lower()
    return (
        "accessdenied" in blob.replace("_", "")
        or "not authorized" in blob
        or "explicit deny" in blob
        or "implicit deny" in blob
    )


def role_boto_kwargs(
    *,
    role_arn: str,
    region: str,
    account_id: str,
    session_name: str,
) -> dict:
    """Boto3 kwargs signed as ``role_arn`` via the gateway (IAM enforced).

    ``connect_to`` marks calls as internal and skips IAM. Real agents hit
    the public APIs with the workload role, so we mint STS creds (moto)
    and call ``127.0.0.1:<gateway>`` — same path IAM_ENFORCEMENT evaluates
    for AccessDenied.
    """
    from botocore.config import Config as BotoConfig
    from localemu import config as _le_config
    from moto.sts.models import sts_backends

    sts_backend = sts_backends[account_id or "000000000000"]["global"]
    assumed = sts_backend.assume_role(
        region_name=region,
        role_session_name=session_name[:64],
        role_arn=role_arn,
        policy=None,
        duration=3600,
        external_id=None,
    )
    gw_port = _le_config.GATEWAY_LISTEN[0].port
    return {
        "region_name": region,
        "endpoint_url": f"http://127.0.0.1:{gw_port}",
        "aws_access_key_id": assumed.access_key_id,
        "aws_secret_access_key": assumed.secret_access_key,
        "aws_session_token": assumed.session_token,
        "config": BotoConfig(
            retries={"max_attempts": 2, "mode": "standard"},
            connect_timeout=5,
            read_timeout=10,
        ),
    }


def resolve_ecr_image(
    image: str,
    *,
    role_arn: str | None,
    region: str,
    account_id: str,
    session_name: str,
    role_label: str = "execution role",
) -> str:
    """Map an ECR image URI to the local registry after ``ecr:BatchGetImage``.

    Non-ECR images (Docker Hub, ``public.ecr.aws``) are unchanged.
    Bytes are pushed to ``AWSBOX_ECR_REGISTRY`` (default ``127.0.0.1:5000``);
    the caller keeps the amazonaws.com URI on the resource.
    """
    match = ECR_IMAGE_RE.match(image)
    if not match:
        return image
    if not role_arn:
        raise RuntimeError(
            f"CannotPullContainerError: {role_label} is not specified "
            "for ECR image pull (ecr:BatchGetImage)"
        )
    import boto3

    ref = match.group("ref")
    repository, image_id = ecr_image_id(ref)
    ecr = boto3.client(
        "ecr",
        **role_boto_kwargs(
            role_arn=role_arn,
            region=region,
            account_id=account_id,
            session_name=session_name,
        ),
    )
    try:
        resp = ecr.batch_get_image(
            repositoryName=repository,
            imageIds=[image_id],
        )
    except Exception as e:
        if is_access_denied(e):
            raise RuntimeError(
                f"CannotPullContainerError: {role_label} is not "
                "authorized to perform ecr:BatchGetImage"
            ) from e
        raise RuntimeError(f"CannotPullContainerError: {e}") from e
    for failure in resp.get("failures") or []:
        code = str(failure.get("failureCode") or "")
        if "accessdenied" in code.lower().replace("_", ""):
            raise RuntimeError(
                f"CannotPullContainerError: {role_label} is not "
                "authorized to perform ecr:BatchGetImage"
            )
    return ecr_local_ref(ref)
