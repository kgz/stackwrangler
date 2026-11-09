"""Map access keys to accounts and evaluate cross-account AssumeRole trust.

``AWSBOX_ACCOUNT_IDS`` is ``key=012345678901`` comma-separated. Those keys are
root in that account. ``AWSBOX_ACCOUNT_ID`` is the fallback when a key would
otherwise stay on ``000000000000``.

Moto encodes the account in ``AKIA`` / ``ASIA`` keys. LocalEmu ignores that
prefix so a pasted production key does not select an account. Keys are decoded
only when the encoded account is one we were configured with (or the default).
"""

from __future__ import annotations

import contextvars
import json
import logging
import os
import re
import sys

LOG = logging.getLogger("localemu.awsbox.multi_account")

_ACCOUNT = re.compile(r"\d{12}")
_LAMBDA_PRINCIPALS = {"lambda", "lambda.amazonaws.com"}
_ASSUME_ACTIONS = {"sts:AssumeRole", "sts:*", "*"}
_SOURCE_ARN_KEYS = {"aws:SourceArn", "AWS:SourceArn"}
_SUPPORTED_CONDITIONS = {
    "StringEquals": {"sts:ExternalId", "sts:externalId", "aws:SourceAccount"},
    "Bool": {"aws:MultiFactorAuthPresent"},
    "ArnLike": _SOURCE_ARN_KEYS,
    "ArnEquals": _SOURCE_ARN_KEYS,
}

# Calling resource when a service assumes a role (function / rule / topic / schedule-group ARN).
_PENDING_SOURCE_ARN: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "awsbox_pending_source_arn", default=None
)
_STS_SOURCE_ARN: contextvars.ContextVar[str | None] = contextvars.ContextVar(
    "awsbox_sts_source_arn", default=None
)


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


def _arn_like(value: str, pattern: str) -> bool:
    regex = "".join(
        ".*" if ch == "*" else "." if ch == "?" else re.escape(ch) for ch in pattern
    )
    return re.fullmatch(regex, value) is not None


def _values(expected: object) -> list[object]:
    return expected if isinstance(expected, list) else [expected]


def _conditions_hold(
    conditions: object,
    external_id: str | None,
    serial_number: str | None,
    source_account: str | None = None,
    source_arn: str | None = None,
) -> bool:
    """True when every condition is one we evaluate and it matches.

    An operator or key we do not know makes the statement not apply, so an
    Allow with ``aws:PrincipalOrgID`` does not become an allow.

    ``source_account`` / ``source_arn`` are only set when an AWS service
    assumes the role; a missing key never satisfies ``aws:SourceAccount``
    or ``aws:SourceArn``.
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
                if source_account not in _values(expected):
                    return False
            elif key in _SOURCE_ARN_KEYS:
                if not source_arn:
                    return False
                patterns = [str(item) for item in _values(expected)]
                if operator == "ArnEquals":
                    if source_arn not in patterns:
                        return False
                elif not any(_arn_like(source_arn, pattern) for pattern in patterns):
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
    """Cross-account S3 needs a bucket-policy Allow for *this* IAM action (#233).

    Root bypasses PolicyEvaluator entirely, so this gate is the only check for
    Root. It must be action-specific: Allow on ListBucket must not open
    GetObject, and an explicit Deny on the requested action must deny.
    """
    from localemu.aws.api.s3 import AccessDenied
    from localemu.services.iam_enforcement import enforcer, resource_policies as rp
    from localemu.services.iam_enforcement.identity import resolve_caller
    from localemu.services.iam_enforcement.service_action_map import map_action
    from localemu.services.s3.provider import S3Provider

    # Bucket-ARN actions (not arn:aws:s3:::bucket/*). Default is object ARN.
    _BUCKET_RESOURCE_ACTIONS = frozenset({
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:ListBucketMultipartUploads",
        "s3:GetBucketLocation",
        "s3:GetBucketTagging",
        "s3:PutBucketTagging",
        "s3:DeleteBucket",
        "s3:CreateBucket",
        "s3:GetEncryptionConfiguration",
        "s3:PutEncryptionConfiguration",
        "s3:GetBucketCORS",
        "s3:PutBucketCORS",
        "s3:GetReplicationConfiguration",
        "s3:PutReplicationConfiguration",
        "s3:GetLifecycleConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:GetBucketPublicAccessBlock",
        "s3:PutBucketPublicAccessBlock",
    })

    def _s3_actions(context) -> list[str]:
        op = getattr(getattr(context, "operation", None), "name", None)
        if not op:
            return ["s3:ListBucket"]
        return map_action("s3", op)

    def _s3_resource_arn(action: str, bucket_name: str) -> str:
        if action in _BUCKET_RESOURCE_ACTIONS:
            return f"arn:aws:s3:::{bucket_name}"
        return f"arn:aws:s3:::{bucket_name}/*"

    def _bucket_policy_allows(context, bucket_name: str, bucket, actions: list[str] | None = None) -> bool:
        policy_raw = getattr(bucket, "policy", None)
        policy = rp._parse_policy(policy_raw) if policy_raw else None
        if not policy:
            return False
        access_key = enforcer._extract_access_key(context)
        account_id = getattr(context, "account_id", None) or "000000000000"
        region = getattr(context, "region", None) or "us-east-1"
        caller = resolve_caller(access_key, account_id, region) if access_key else None
        if caller is None:
            return False
        conditions = {"aws:RequestedRegion": region}
        needed = actions if actions is not None else _s3_actions(context)
        # Every IAM action this operation maps to must be Allowed (Deny/neutral fail).
        for action in needed:
            arn = _s3_resource_arn(action, bucket_name)
            if rp.resource_policy_effect(policy, caller, action, arn, conditions) != "allow":
                return False
        return bool(needed)

    original_lookup = S3Provider._get_cross_account_bucket

    def _get_cross_account_bucket(self, context, bucket_name, *args, **kwargs):
        store, bucket = original_lookup(self, context, bucket_name, *args, **kwargs)
        owner = getattr(bucket, "bucket_account_id", None)
        caller = getattr(context, "account_id", None)
        if owner and caller and owner != caller and not _bucket_policy_allows(context, bucket_name, bucket):
            raise AccessDenied("Access Denied")
        return store, bucket

    S3Provider._get_cross_account_bucket = _get_cross_account_bucket

    original_head = S3Provider.head_bucket

    def head_bucket(self, context, bucket, expected_bucket_owner=None, **kwargs):
        if bucket != "__health_check__":
            store = self.get_store(context.account_id, context.region)
            owner = store.global_bucket_map.get(bucket)
            if owner and owner != context.account_id:
                try:
                    from localemu.constants import AWS_REGION_US_EAST_1
                    from localemu.services.s3.models import s3_stores

                    remote = s3_stores[owner][AWS_REGION_US_EAST_1].buckets.get(bucket)
                except Exception:
                    remote = None
                # HeadBucket → s3:ListBucket even if operation is missing on context.
                if remote is None or not _bucket_policy_allows(
                    context, bucket, remote, actions=["s3:ListBucket"],
                ):
                    raise AccessDenied("Access Denied")
        return original_head(
            self,
            context,
            bucket,
            expected_bucket_owner=expected_bucket_owner,
            **kwargs,
        )

    S3Provider.head_bucket = head_bucket


def _account_from_arn(arn: str | None) -> str | None:
    if not arn:
        return None
    parts = arn.split(":")
    if len(parts) >= 5 and _ACCOUNT.fullmatch(parts[4]):
        return parts[4]
    return None


def _source_arn(service_principal: str | None) -> str | None:
    """aws:SourceArn from the calling resource on a service AssumeRole."""
    if not service_principal:
        return None
    pending = _STS_SOURCE_ARN.get() or _PENDING_SOURCE_ARN.get()
    return pending if isinstance(pending, str) and pending else None


def _source_account(role: object, service_principal: str | None) -> str | None:
    """Account AWS reports as aws:SourceAccount when a service assumes the role.

    Prefer the calling resource ARN. Lambda CreateFunction has no other
    account on the assume call, so the role's account stands in when the
    function ARN is missing. A user call never gets a value.
    """
    if not service_principal:
        return None
    from_arn = _account_from_arn(_source_arn(service_principal))
    if from_arn:
        return from_arn
    if (service_principal or "").lower() not in _LAMBDA_PRINCIPALS:
        return None
    return _account_from_arn(str(getattr(role, "arn", "") or ""))


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
                _source_arn(service_principal),
            ):
                continue
            if effect == "deny":
                return False
            allow = True
        return allow

    sts_provider._evaluate_trust_policy = _evaluate_trust_policy


def _function_arn_for_create(context: object, request: object) -> str | None:
    getter = getattr(request, "get", None)
    raw = None
    if callable(getter):
        raw = getter("FunctionName")
        if raw is None:
            raw = getter("function_name")
    if not isinstance(raw, str) or not raw:
        return None
    from localemu.services.lambda_ import api_utils

    name, _qualifier, account, region = api_utils.function_locators_from_arn(raw)
    if not name:
        return None
    account_id = account or getattr(context, "account_id", None)
    region_name = region or getattr(context, "region", None)
    if not isinstance(account_id, str) or not isinstance(region_name, str):
        return None
    return api_utils.unqualified_lambda_arn(name, account_id, region_name)


def _copy_handler(dst: object, src: object) -> None:
    for attr in ("operation", "expand_parameters", "pass_context"):
        if hasattr(src, attr):
            setattr(dst, attr, getattr(src, attr))



def _schedule_group_source_arn(schedule_arn: str) -> str | None:
    """``…:schedule/<group>/<name>`` → ``…:schedule-group/<group>`` for trust SourceArn."""
    marker = ":schedule/"
    idx = schedule_arn.find(marker)
    if idx < 0:
        return None
    rest = schedule_arn[idx + len(marker) :]
    group, sep, _name = rest.partition("/")
    if not sep or not group:
        return None
    return f"{schedule_arn[:idx]}:schedule-group/{group}"


def _service_principal_label(service_principal: object) -> str:
    text = str(service_principal).strip()
    if not text:
        return "unknown.amazonaws.com"
    if "." not in text:
        return f"{text}.amazonaws.com"
    return text


def _install_source_arn() -> None:
    """Carry the calling resource ARN on service AssumeRole."""
    from localemu.aws.connect import MetadataRequestInjector
    from localemu.services.lambda_.invocation.execution_environment import (
        ExecutionEnvironment,
    )
    from localemu.services.lambda_.provider import LambdaProvider
    from localemu.services.sts.provider import StsProvider

    original_metadata = MetadataRequestInjector.request_metadata

    def request_metadata(
        self,
        source_arn: str | None = None,
        service_principal: str | None = None,
    ):
        if not source_arn:
            source_arn = _PENDING_SOURCE_ARN.get()
        return original_metadata(
            self, source_arn=source_arn, service_principal=service_principal
        )

    MetadataRequestInjector.request_metadata = request_metadata

    original_assume = StsProvider.assume_role

    def assume_role(self, context, *args, **kwargs):
        internal = getattr(context, "internal_request_params", None)
        raw = None
        service_principal = None
        if internal is not None:
            getter = getattr(internal, "get", None)
            if callable(getter):
                raw = getter("source_arn")
                service_principal = getter("service_principal")
        token = _STS_SOURCE_ARN.set(raw if isinstance(raw, str) else None)
        try:
            return original_assume(self, context, *args, **kwargs)
        except Exception as exc:
            code = getattr(exc, "code", None)
            msg = str(getattr(exc, "message", "") or "")
            if (
                service_principal
                and code == "AccessDenied"
                and "sts:AssumeRole" in msg
                and msg.startswith("User:")
            ):
                from localemu.aws.api import CommonServiceException

                label = _service_principal_label(service_principal)
                rewritten = re.sub(r"^User:\s+\S+", f"User: {label}", msg, count=1)
                raise CommonServiceException(
                    code="AccessDenied",
                    message=rewritten,
                    status_code=int(getattr(exc, "status_code", 403) or 403),
                    sender_fault=bool(getattr(exc, "sender_fault", False)),
                ) from None
            raise
        finally:
            _STS_SOURCE_ARN.reset(token)

    _copy_handler(assume_role, original_assume)
    StsProvider.assume_role = assume_role

    original_create = LambdaProvider.create_function

    def create_function(self, context, request):
        token = _PENDING_SOURCE_ARN.set(_function_arn_for_create(context, request))
        try:
            return original_create(self, context, request)
        finally:
            _PENDING_SOURCE_ARN.reset(token)

    _copy_handler(create_function, original_create)
    LambdaProvider.create_function = create_function

    original_creds = ExecutionEnvironment.get_credentials

    def get_credentials(self):
        token = _PENDING_SOURCE_ARN.set(self.function_version.id.unqualified_arn())
        try:
            return original_creds(self)
        finally:
            _PENDING_SOURCE_ARN.reset(token)

    ExecutionEnvironment.get_credentials = get_credentials

    try:
        from localemu.services.apigateway.next_gen.execute_api.integrations import (
            aws as apigw_aws,
        )

        original_headers = apigw_aws._get_internal_mocked_headers_cached

        def _get_internal_mocked_headers_cached(
            service_name, region_name, source_arn, role_arn=None
        ):
            token = _PENDING_SOURCE_ARN.set(source_arn if source_arn else None)
            try:
                return original_headers(
                    service_name, region_name, source_arn, role_arn
                )
            finally:
                _PENDING_SOURCE_ARN.reset(token)

        apigw_aws._get_internal_mocked_headers_cached = (
            _get_internal_mocked_headers_cached
        )
    except Exception as exc:
        LOG.debug("apigw source_arn wrap skipped: %s", exc)

    try:
        from localemu.services.scheduler import target_invoker as scheduler_target

        original_invoke = scheduler_target.invoke

        def invoke(
            *,
            schedule_arn: str,
            schedule_name: str,
            target: dict,
            account_id: str,
            region: str,
        ):
            # AWS documents trust ArnLike on the schedule-group ARN (#665).
            group_arn = _schedule_group_source_arn(schedule_arn)
            token = _PENDING_SOURCE_ARN.set(group_arn)
            try:
                return original_invoke(
                    schedule_arn=schedule_arn,
                    schedule_name=schedule_name,
                    target=target,
                    account_id=account_id,
                    region=region,
                )
            finally:
                _PENDING_SOURCE_ARN.reset(token)

        scheduler_target.invoke = invoke
    except Exception as exc:
        LOG.debug("scheduler source_arn wrap skipped: %s", exc)


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
    try:
        _install_source_arn()
    except Exception as exc:
        LOG.error("awsbox source_arn trust wrap failed: %s", exc)
    LOG.info(
        "awsbox multi-account applied (default=%s, keys=%s)",
        default or "-",
        ",".join(sorted(per_key)),
    )
    print("awsbox multi-account applied", flush=True)


_apply()
