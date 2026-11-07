"""Resolve CloudFormation deployer credentials for resource-provider calls (#524).

AWS: without a stack RoleARN, CFN resource ops run as the caller; with RoleARN,
as that service role (caller needs iam:PassRole). LocalEmu previously always
signed with INTERNAL credentials, so IAM never saw deploy-role gaps.
"""

from __future__ import annotations

import logging
from typing import Any

from localemu.constants import (
    INTERNAL_AWS_ACCESS_KEY_ID,
    INTERNAL_AWS_SECRET_ACCESS_KEY,
)

LOG = logging.getLogger(__name__)

CredentialsDict = dict[str, str]


def _internal_credentials() -> CredentialsDict:
    return {
        "accessKeyId": INTERNAL_AWS_ACCESS_KEY_ID,
        "secretAccessKey": INTERNAL_AWS_SECRET_ACCESS_KEY,
        "sessionToken": "",
    }


def _credentials_for_access_key(access_key_id: str, account_id: str) -> CredentialsDict:
    """Look up signing material for a known access key (user or assumed-role)."""
    try:
        from moto.sts.models import sts_backends

        assumed = sts_backends[account_id]["global"].get_assumed_role_from_access_key(
            access_key_id
        )
        if assumed:
            return {
                "accessKeyId": assumed.access_key_id,
                "secretAccessKey": assumed.secret_access_key,
                "sessionToken": assumed.session_token or "",
            }
    except Exception as exc:
        LOG.debug("CFN deploy creds: STS lookup failed for %s: %s", access_key_id[:8], exc)

    try:
        from moto.iam.models import iam_backends

        backend = iam_backends[account_id]["global"]
        key = None
        if hasattr(backend, "access_keys") and isinstance(backend.access_keys, dict):
            key = backend.access_keys.get(access_key_id)
        if key is None:
            for user in backend.users.values():
                for candidate in user.access_keys:
                    if (
                        candidate.access_key_id == access_key_id
                        and getattr(candidate, "status", "Active") == "Active"
                    ):
                        key = candidate
                        break
                if key is not None:
                    break
        if key is not None:
            return {
                "accessKeyId": key.access_key_id,
                "secretAccessKey": key.secret_access_key,
                "sessionToken": "",
            }
    except Exception as exc:
        LOG.debug("CFN deploy creds: IAM lookup failed for %s: %s", access_key_id[:8], exc)

    # LocalEmu does not verify SigV4; access key id drives IAM identity.
    return {
        "accessKeyId": access_key_id,
        "secretAccessKey": INTERNAL_AWS_SECRET_ACCESS_KEY,
        "sessionToken": "",
    }


def _assume_service_role(
    *,
    role_arn: str,
    account_id: str,
    region: str,
) -> CredentialsDict:
    from moto.sts.models import sts_backends

    role_account = account_id
    if role_arn.startswith("arn:") and role_arn.count(":") >= 4:
        role_account = role_arn.split(":")[4] or account_id
    assumed = sts_backends[role_account]["global"].assume_role(
        region_name=region,
        role_session_name="AWSCloudFormation",
        role_arn=role_arn,
        policy=None,
        duration=3600,
        external_id=None,
    )
    return {
        "accessKeyId": assumed.access_key_id,
        "secretAccessKey": assumed.secret_access_key,
        "sessionToken": assumed.session_token or "",
    }


def bind_deploy_credentials(stack: Any, context: Any, role_arn: str | None = None) -> None:
    """Attach deployer credentials to ``stack`` for the upcoming resource ops.

    Root / admin keys keep the internal sentinel (IAM skipped), matching prior
    behaviour. Non-root callers use their session, or the stack RoleARN when set.
    """
    from localemu.services.iam_enforcement.enforcer import _extract_access_key
    from localemu.services.iam_enforcement.identity import resolve_caller

    if role_arn:
        stack.role_arn = role_arn
    effective_role = role_arn or getattr(stack, "role_arn", None)

    access_key = _extract_access_key(context)
    account_id = getattr(context, "account_id", None) or stack.account_id
    region = getattr(context, "region", None) or stack.region_name

    caller = resolve_caller(access_key, account_id, region) if access_key else None
    if not caller or caller.principal_type == "Root":
        stack.deploy_credentials = _internal_credentials()
        LOG.info(
            "CFN deploy creds: stack=%s using internal sentinel (caller=%s key=%s)",
            getattr(stack, "stack_name", "?"),
            getattr(caller, "principal_type", None),
            (access_key or "")[:8],
        )
        return

    if effective_role:
        try:
            stack.deploy_credentials = _assume_service_role(
                role_arn=effective_role,
                account_id=account_id,
                region=region,
            )
        except Exception as exc:
            LOG.warning(
                "CFN deploy creds: failed to assume RoleARN %s: %s",
                effective_role,
                exc,
            )
            raise
        LOG.info(
            "CFN deploy creds: stack=%s using RoleARN %s as %s",
            getattr(stack, "stack_name", "?"),
            effective_role,
            stack.deploy_credentials["accessKeyId"][:8],
        )
        return

    stack.deploy_credentials = _credentials_for_access_key(access_key, account_id)
    LOG.info(
        "CFN deploy creds: stack=%s using caller %s key=%s session=%s",
        getattr(stack, "stack_name", "?"),
        caller.principal_type,
        stack.deploy_credentials["accessKeyId"][:8],
        "yes" if stack.deploy_credentials.get("sessionToken") else "no",
    )


def stack_deploy_credentials(stack: Any) -> CredentialsDict:
    """Credentials for resource-provider payloads; internal sentinel if unset."""
    creds = getattr(stack, "deploy_credentials", None)
    if isinstance(creds, dict) and creds.get("accessKeyId"):
        return {
            "accessKeyId": creds["accessKeyId"],
            "secretAccessKey": creds.get("secretAccessKey") or INTERNAL_AWS_SECRET_ACCESS_KEY,
            "sessionToken": creds.get("sessionToken") or "",
        }
    return _internal_credentials()
