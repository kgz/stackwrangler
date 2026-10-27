"""Map access keys to accounts and evaluate cross-account AssumeRole trust.

``AWSBOX_ACCOUNT_IDS`` is ``key=012345678901`` comma-separated. Those keys are
root in that account. ``AWSBOX_ACCOUNT_ID`` is the fallback when a key would
otherwise stay on ``000000000000``.

Moto encodes the account in ``AKIA`` / ``ASIA`` keys. LocalEmu ignores that
prefix so a pasted production key does not select an account. Keys are decoded
only when the encoded account is one we were configured with (or the default).
"""

from __future__ import annotations

import json
import logging
import os
import re
import sys

LOG = logging.getLogger("localemu.awsbox.multi_account")

_ACCOUNT = re.compile(r"\d{12}")
_ASSUME_ACTIONS = {"sts:AssumeRole", "sts:*", "*"}
_SUPPORTED_CONDITIONS = {
    "StringEquals": {"sts:ExternalId", "sts:externalId", "aws:SourceAccount"},
    "Bool": {"aws:MultiFactorAuthPresent"},
}


def _parse_account_map(raw: str) -> dict[str, str]:
    parsed: dict[str, str] = {}
    for part in raw.split(","):
        item = part.strip()
        if not item:
            continue
        key, sep, account = item.partition("=")
        key = key.strip()
        account = account.strip()
        if not sep or not key or _ACCOUNT.fullmatch(account) is None:
            LOG.error("ignoring bad AWSBOX_ACCOUNT_IDS entry %r", item)
            continue
        parsed[key] = account
    return parsed


def _conditions_hold(
    conditions: object,
    external_id: str | None,
    serial_number: str | None,
    source_account: str | None = None,
) -> bool:
    """True when every condition is one we evaluate and it matches.

    An operator or key we do not know makes the statement not apply, so an
    Allow with ``aws:PrincipalOrgID`` does not become an allow.

    ``source_account`` is only set when an AWS service assumes the role; a
    missing key never satisfies ``aws:SourceAccount``.
    """
    if not conditions:
        return True
    if not isinstance(conditions, dict):
        return False
    for operator, body in conditions.items():
        allowed_keys = _SUPPORTED_CONDITIONS.get(operator)
        if allowed_keys is None or not isinstance(body, dict):
            return False
        for key, expected in body.items():
            if key not in allowed_keys:
                return False
            if key.lower() == "sts:externalid":
                if isinstance(expected, list):
                    if external_id not in expected:
                        return False
                elif external_id != expected:
                    return False
            elif key == "aws:SourceAccount":
                if not source_account:
                    return False
                accounts = expected if isinstance(expected, list) else [expected]
                if source_account not in accounts:
                    return False
            elif key == "aws:MultiFactorAuthPresent" and str(expected).lower() == "true":
                if not serial_number:
                    return False
    return True


def _action_allows_assume(statement: dict[str, object]) -> bool:
    if "NotAction" in statement:
        return False
    action = statement.get("Action", [])
    if isinstance(action, str):
        action = [action]
    if not isinstance(action, list):
        return False
    return any(item in _ASSUME_ACTIONS for item in action)


def _install_s3_isolation() -> None:
    """A bucket owned by another account is not readable from this one.

    Bucket policies that grant the other account are #233. Until then the
    other account's objects stay hidden.
    """
    from localemu.aws.api.s3 import AccessDenied
    from localemu.services.s3.provider import S3Provider

    original_lookup = S3Provider._get_cross_account_bucket

    def _get_cross_account_bucket(self, context, bucket_name, *args, **kwargs):
        store, bucket = original_lookup(self, context, bucket_name, *args, **kwargs)
        owner = getattr(bucket, "bucket_account_id", None)
        caller = getattr(context, "account_id", None)
        if owner and caller and owner != caller:
            raise AccessDenied("Access Denied")
        return store, bucket

    S3Provider._get_cross_account_bucket = _get_cross_account_bucket

    original_head = S3Provider.head_bucket

    def head_bucket(self, context, bucket, expected_bucket_owner=None, **kwargs):
        if bucket != "__health_check__":
            store = self.get_store(context.account_id, context.region)
            owner = store.global_bucket_map.get(bucket)
            if owner and owner != context.account_id:
                raise AccessDenied("Access Denied")
        return original_head(
            self,
            context,
            bucket,
            expected_bucket_owner=expected_bucket_owner,
            **kwargs,
        )

    S3Provider.head_bucket = head_bucket


def _source_account(role: object, service_principal: str | None) -> str | None:
    """Account AWS reports as aws:SourceAccount when a service assumes the role.

    Lambda only accepts roles from the function's own account, so the role's
    account stands in for the function account (the assume call carries no
    other account).
    """
    if not service_principal:
        return None
    arn = str(getattr(role, "arn", "") or "")
    parts = arn.split(":")
    if len(parts) >= 5 and _ACCOUNT.fullmatch(parts[4]):
        return parts[4]
    return None


def _install_trust() -> None:
    import localemu.services.sts.provider as sts_provider

    principal_matches = sts_provider._trust_principal_matches

    def _evaluate_trust_policy(
        role: object,
        caller_arn: str,
        caller_account_id: str,
        external_id: str | None = None,
        serial_number: str | None = None,
        service_principal: str | None = None,
    ) -> bool:
        trust_doc_str = getattr(role, "assume_role_policy_document", None)
        if not trust_doc_str:
            return False
        try:
            if isinstance(trust_doc_str, str):
                trust_doc = json.loads(trust_doc_str)
            else:
                trust_doc = trust_doc_str
        except (json.JSONDecodeError, TypeError):
            LOG.debug(
                "Failed to parse trust policy for role %s",
                getattr(role, "name", "unknown"),
            )
            return False
        if not isinstance(trust_doc, dict):
            return False
        statements = trust_doc.get("Statement", [])
        if isinstance(statements, dict):
            statements = [statements]
        if not isinstance(statements, list):
            return False

        allow = False
        for statement in statements:
            if not isinstance(statement, dict):
                return False
            effect = str(statement.get("Effect", "")).lower()
            if effect not in ("allow", "deny"):
                continue
            if not _action_allows_assume(statement):
                continue
            principal = statement.get("Principal")
            if not principal:
                continue
            if not principal_matches(
                principal,
                caller_arn,
                caller_account_id,
                service_principal=service_principal,
            ):
                continue
            if not _conditions_hold(
                statement.get("Condition") or {},
                external_id,
                serial_number,
                _source_account(role, service_principal),
            ):
                continue
            if effect == "deny":
                return False
            allow = True
        return allow

    sts_provider._evaluate_trust_policy = _evaluate_trust_policy


def _install_root_keys(per_key: dict[str, str]) -> None:
    if not per_key:
        return
    import localemu.services.iam_enforcement.identity as identity
    import localemu.services.sts.provider as sts_provider

    def _wrap(module: object) -> None:
        original = module._get_root_access_keys

        def _get_root_access_keys() -> set[str]:
            keys = set(original())
            keys.update(per_key)
            return keys

        module._get_root_access_keys = _get_root_access_keys

    _wrap(identity)
    _wrap(sts_provider)


def _install_account_ids(per_key: dict[str, str], default: str) -> None:
    from localemu.aws import accounts as accounts_mod
    from localemu.constants import DEFAULT_AWS_ACCOUNT_ID

    known = set(per_key.values())
    known.add(DEFAULT_AWS_ACCOUNT_ID)
    if default:
        known.add(default)

    original = accounts_mod.get_account_id_from_access_key_id
    extract = accounts_mod.extract_account_id_from_access_key_id

    def get_account_id_from_access_key_id(access_key_id: str) -> str:
        if not access_key_id:
            return original(access_key_id)
        mapped = per_key.get(access_key_id)
        if mapped:
            return mapped
        if access_key_id.startswith(("AKIA", "ASIA")):
            extracted = extract(access_key_id)
            if extracted in known:
                return extracted
        resolved = original(access_key_id)
        if default and resolved == DEFAULT_AWS_ACCOUNT_ID:
            return default
        return resolved

    accounts_mod.get_account_id_from_access_key_id = get_account_id_from_access_key_id
    for module in list(sys.modules.values()):
        namespace = getattr(module, "__dict__", None)
        if not isinstance(namespace, dict):
            continue
        for name, value in list(namespace.items()):
            if value is original:
                namespace[name] = get_account_id_from_access_key_id


def _apply() -> None:
    per_key = _parse_account_map(os.environ.get("AWSBOX_ACCOUNT_IDS", ""))
    default = os.environ.get("AWSBOX_ACCOUNT_ID", "").strip()
    if default and _ACCOUNT.fullmatch(default) is None:
        LOG.error("AWSBOX_ACCOUNT_ID must be 12 digits, ignoring %r", default)
        default = ""
    _install_account_ids(per_key, default)
    _install_root_keys(per_key)
    _install_s3_isolation()
    _install_trust()
    LOG.info(
        "awsbox multi-account applied (default=%s, keys=%s)",
        default or "-",
        ",".join(sorted(per_key)),
    )
    print("awsbox multi-account applied", flush=True)


_apply()
