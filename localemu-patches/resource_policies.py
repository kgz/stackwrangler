"""Cross-account resource-based policy evaluator.

When the caller (account A) targets a resource owned by account B, the
identity-based policies in A allow the action but real AWS only completes
the request if the resource-based policy on B explicitly authorises A.
This module loads the resource-based policy from the target service
backend, runs it through the same condition-key / action / principal
matching used by identity policies, and produces an ALLOW / DENY /
NEUTRAL decision.

Handlers covered (each with its own ``_load_*_policy`` loader):

* S3 bucket policy             — LocalEmu ``s3_stores`` FakeBucket.policy
* SQS queue policy             — moto: ``queue.policy``
* SNS topic policy             — moto: ``topic.policy``
* KMS key policy               — moto: ``key.policy`` (JSON string)
* Secrets Manager resource policy — moto: ``secret.policy``
* Lambda function policy       — moto: ``function.policy._policy``
* EventBridge bus policy       — moto: ``event_bus.policy``

``evaluate_cross_account`` stays cross-account only (same-account returns
``NEUTRAL`` so S3 replication is unchanged). Same-account documents are
applied by the IAM enforcer. KMS is stricter than other resource policies:
``evaluate_kms_crypto`` allows a call when the key policy names the caller,
or when it delegates to IAM (account-root Allow) and an identity policy
allows the action. An identity Allow alone is not enough.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from enum import Enum
from typing import Any

LOG = logging.getLogger(__name__)


class Decision(Enum):
    NEUTRAL = "neutral"          # not a cross-account call, or no policy hits
    ALLOW = "allow"              # explicit allow in the resource policy
    EXPLICIT_DENY = "deny"       # explicit deny in the resource policy


@dataclass
class ResourceTarget:
    """The resource being accessed."""
    service: str
    arn: str
    account_id: str         # account that OWNS the resource
    region: str
    name: str               # bucket name / queue name / function name / etc.


# --------------------------------------------------------------------------
# Per-service policy loaders
# --------------------------------------------------------------------------


def _load_s3_bucket_policy(target: ResourceTarget) -> dict | None:
    """Load the bucket policy from LocalEmu's native S3 store.

    LocalEmu owns S3's data plane (the buckets live in
    ``localemu.services.s3.models.s3_stores`` and the policy hangs off
    the FakeBucket), so we read from there. moto's ``s3_backends`` does
    not have the bucket.
    """
    try:
        from localemu.constants import AWS_REGION_US_EAST_1
        from localemu.services.s3.models import s3_stores

        store = s3_stores[target.account_id][AWS_REGION_US_EAST_1]
        bucket = store.buckets.get(target.name)
        if bucket is None:
            owner = store.global_bucket_map.get(target.name) \
                if hasattr(store, "global_bucket_map") else None
            if owner:
                bucket = s3_stores[owner][AWS_REGION_US_EAST_1].buckets.get(
                    target.name,
                )
        if bucket is None:
            return None
        policy = getattr(bucket, "policy", None)
        if policy is None:
            return None
        if isinstance(policy, (bytes, bytearray)):
            policy = policy.decode("utf-8")
        if isinstance(policy, str):
            try:
                return json.loads(policy)
            except json.JSONDecodeError:
                return None
        if isinstance(policy, dict):
            return policy
        return None
    except Exception as e:
        LOG.debug("S3 bucket policy load failed for %s: %s", target.arn, e)
        return None


def _load_sqs_queue_policy(target: ResourceTarget) -> dict | None:
    # LocalEmu SQS is native (sqs_stores); moto is a fallback only.
    try:
        from localemu.services.sqs.models import sqs_stores

        store = sqs_stores[target.account_id][target.region]
        queues = getattr(store, "queues", None) or {}
        for queue in queues.values() if isinstance(queues, dict) else queues:
            arn = getattr(queue, "arn", None)
            name = getattr(queue, "name", None) or getattr(queue, "queue_name", None)
            if arn == target.arn or name == target.name:
                return _parse_policy(
                    (getattr(queue, "attributes", None) or {}).get("Policy")
                    or getattr(queue, "policy", None),
                )
    except Exception as e:
        LOG.debug("SQS native policy load failed for %s: %s", target.arn, e)

    try:
        from moto.sqs import sqs_backends
        backend = sqs_backends[target.account_id][target.region]
        queue = backend.queues.get(target.name)
        if queue is None:
            return None
        return _parse_policy(
            getattr(queue, "policy", None)
            or getattr(queue, "attributes", {}).get("Policy"),
        )
    except Exception as e:
        LOG.debug("SQS policy load failed for %s: %s", target.arn, e)
        return None


def _load_sns_topic_policy(target: ResourceTarget) -> dict | None:
    try:
        from moto.sns import sns_backends
        backend = sns_backends[target.account_id][target.region]
        topic = None
        for arn, t in (getattr(backend, "topics", {}) or {}).items():
            if arn == target.arn or getattr(t, "name", None) == target.name:
                topic = t
                break
        if topic is None:
            return None
        policy = getattr(topic, "policy", None)
        if isinstance(policy, str):
            try:
                return json.loads(policy)
            except json.JSONDecodeError:
                return None
        if isinstance(policy, dict):
            return policy
        return None
    except Exception as e:
        LOG.debug("SNS topic policy load failed for %s: %s", target.arn, e)
        return None


def _load_kms_key_policy(target: ResourceTarget) -> dict | None:
    # LocalEmu KMS is native (kms_stores), not moto.
    return load_kms_key_policy(target.arn or target.name, target.account_id, target.region)


def _load_lambda_function_policy(target: ResourceTarget) -> dict | None:
    try:
        from moto.awslambda import lambda_backends
        backend = lambda_backends[target.account_id][target.region]
        function = backend.get_function(target.name) if hasattr(backend, "get_function") else None
        if function is None:
            return None
        raw = getattr(function, "policy", None)
        # moto wraps the function policy in a Policy object with ``_policy`` dict
        if raw is None:
            return None
        if hasattr(raw, "_policy"):
            raw = raw._policy
        if isinstance(raw, str):
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                return None
        if isinstance(raw, dict):
            return raw
        return None
    except Exception as e:
        LOG.debug("Lambda policy load failed for %s: %s", target.arn, e)
        return None


def _load_event_bus_policy(target: ResourceTarget) -> dict | None:
    try:
        from moto.events import events_backends
        backend = events_backends[target.account_id][target.region]
        bus = None
        for b in (getattr(backend, "event_buses", {}) or {}).values():
            if getattr(b, "arn", None) == target.arn or getattr(b, "name", None) == target.name:
                bus = b
                break
        if bus is None:
            return None
        policy = getattr(bus, "policy", None)
        if isinstance(policy, str):
            try:
                return json.loads(policy)
            except json.JSONDecodeError:
                return None
        if isinstance(policy, dict):
            return policy
        return None
    except Exception as e:
        LOG.debug("EventBridge bus policy load failed for %s: %s", target.arn, e)
        return None


def _load_secretsmanager_policy(target: ResourceTarget) -> dict | None:
    ident = target.arn or target.name
    return load_secretsmanager_policy_doc(ident, target.account_id, target.region)


_LOADERS = {
    "s3":     _load_s3_bucket_policy,
    "sqs":    _load_sqs_queue_policy,
    "sns":    _load_sns_topic_policy,
    "kms":    _load_kms_key_policy,
    "secretsmanager": _load_secretsmanager_policy,
    "lambda": _load_lambda_function_policy,
    "events": _load_event_bus_policy,
}


# --------------------------------------------------------------------------
# Evaluator
# --------------------------------------------------------------------------


def _role_arn_from_assumed_session(caller_arn: str) -> str | None:
    """Map ``arn:aws:sts::acct:assumed-role/role/session`` to the IAM role ARN.

    Resource policies name the role. The signed caller is the session.
    """
    marker = ":assumed-role/"
    if not caller_arn or marker not in caller_arn:
        return None
    parts = caller_arn.split(":")
    if len(parts) < 6:
        return None
    account = parts[4]
    role = caller_arn.split(marker, 1)[1].split("/", 1)[0]
    if not account or not role:
        return None
    return f"arn:aws:iam::{account}:role/{role}"


def _principal_matches(principal_block: Any, caller_account: str,
                       caller_arn: str, caller_org_id: str | None) -> bool:
    """Match a Principal block against the caller.

    Handles:
      - "*"  (everyone)
      - {"AWS": <arn or account-id or list>}
      - {"AWS": "*"}
    Notably does NOT support Service / Federated / CanonicalUser (rarely
    needed for cross-account; can be added later).
    """
    if principal_block == "*":
        return True
    if isinstance(principal_block, dict):
        # AWS field
        aws_p = principal_block.get("AWS")
        if aws_p is None:
            return False
        if isinstance(aws_p, str):
            aws_p = [aws_p]
        if not isinstance(aws_p, list):
            return False
        for p in aws_p:
            ps = str(p).strip()
            if ps == "*":
                return True
            # 12-digit ID
            if ps == caller_account:
                return True
            # arn:aws:iam::<acct>:root
            if ps == f"arn:aws:iam::{caller_account}:root":
                return True
            # exact ARN match against caller_arn (user / role / assumed-role)
            if ps == caller_arn:
                return True
            role_arn = _role_arn_from_assumed_session(caller_arn)
            if role_arn and ps == role_arn:
                return True
        return False
    return False


def _action_matches(statement_action: Any, action: str) -> bool:
    if statement_action == "*":
        return True
    actions = statement_action if isinstance(statement_action, list) else [statement_action]
    action_lower = action.lower()
    for a in actions:
        a_lower = str(a).lower()
        if a_lower == "*" or a_lower == action_lower:
            return True
        # service:* form
        if a_lower.endswith(":*"):
            prefix = a_lower[:-1]   # keep the colon
            if action_lower.startswith(prefix):
                return True
        # glob via fnmatch semantics on the action string
        import fnmatch
        if fnmatch.fnmatchcase(action_lower, a_lower):
            return True
    return False


def _resource_matches(statement_resource: Any, resource_arn: str) -> bool:
    if statement_resource == "*":
        return True
    if statement_resource is None:
        return True
    resources = (statement_resource if isinstance(statement_resource, list)
                 else [statement_resource])
    import fnmatch
    for r in resources:
        rs = str(r)
        if rs == "*":
            return True
        if rs == resource_arn:
            return True
        if fnmatch.fnmatchcase(resource_arn, rs):
            return True
    return False


def evaluate_resource_policy(
    policy: dict,
    target: ResourceTarget,
    caller_account: str,
    caller_arn: str,
    action: str,
    caller_org_id: str | None = None,
    condition_context: dict | None = None,
) -> Decision:
    """Walk the resource policy statements and return a Decision.

    Standard IAM evaluation: explicit Deny beats Allow; only one explicit
    Allow is required for a positive decision; otherwise NEUTRAL (which
    callers treat as a deny for cross-account because real AWS requires
    an explicit allow on the resource policy for cross-account access).
    """
    from .condition_evaluator import matches_conditions

    if not isinstance(policy, dict):
        return Decision.NEUTRAL
    statements = policy.get("Statement")
    if statements is None:
        return Decision.NEUTRAL
    if isinstance(statements, dict):
        statements = [statements]

    saw_allow = False
    ctx = dict(condition_context or {})
    ctx.setdefault("aws:PrincipalAccount", caller_account)
    ctx.setdefault("aws:ResourceAccount", target.account_id)
    if caller_org_id:
        ctx.setdefault("aws:PrincipalOrgID", caller_org_id)

    for st in statements:
        if not isinstance(st, dict):
            continue
        effect = str(st.get("Effect", "")).lower()
        principal = st.get("Principal") or st.get("NotPrincipal")
        if not _principal_matches(principal, caller_account, caller_arn, caller_org_id):
            continue
        if not _action_matches(st.get("Action") or st.get("NotAction"), action):
            continue
        if not _resource_matches(st.get("Resource") or st.get("NotResource"),
                                 target.arn):
            continue
        if not matches_conditions(st, ctx):
            continue
        if effect == "deny":
            return Decision.EXPLICIT_DENY
        if effect == "allow":
            saw_allow = True

    return Decision.ALLOW if saw_allow else Decision.NEUTRAL


def evaluate_cross_account(
    caller_account: str,
    caller_arn: str,
    target: ResourceTarget,
    action: str,
    caller_org_id: str | None = None,
    condition_context: dict | None = None,
) -> Decision:
    """Top-level entry: load the resource policy and evaluate it.

    Returns:
      - NEUTRAL if same-account, no policy, or no matching statement
      - ALLOW if at least one matching Allow with no explicit Deny
      - EXPLICIT_DENY if any matching Deny
    """
    if caller_account == target.account_id:
        return Decision.NEUTRAL

    loader = _LOADERS.get(target.service)
    if loader is None:
        return Decision.NEUTRAL  # service not in scope; let identity eval rule

    policy = loader(target)
    if not policy:
        return Decision.NEUTRAL

    return evaluate_resource_policy(
        policy, target, caller_account, caller_arn, action,
        caller_org_id=caller_org_id,
        condition_context=condition_context,
    )


# --------------------------------------------------------------------------
# Secrets Manager + KMS key-policy decisions (same-account included)
# --------------------------------------------------------------------------


def _parse_policy(policy: Any) -> dict | None:
    if policy is None:
        return None
    if isinstance(policy, (bytes, bytearray)):
        policy = policy.decode("utf-8")
    if isinstance(policy, str):
        try:
            parsed = json.loads(policy)
        except json.JSONDecodeError:
            return None
        return parsed if isinstance(parsed, dict) else None
    if isinstance(policy, dict):
        return policy
    return None


def _customer_managed_key(key_id: str | None) -> str | None:
    """Customer CMK reference. AWS-managed ``alias/aws/*`` keys are not gated."""
    if not key_id or not isinstance(key_id, str):
        return None
    if key_id.startswith("alias/aws/") or ":alias/aws/" in key_id:
        return None
    return key_id


def find_secret(account_id: str, region: str, ident: str):
    """Resolve a secret by name, full ARN, or the unsuffixed ARN the enforcer builds."""
    if not ident:
        return None
    try:
        from moto.secretsmanager.models import secretsmanager_backends

        backend = secretsmanager_backends[account_id][region]
        secret = backend.secrets.get(ident)
        if secret is not None:
            return secret
        name = ident.split(":secret:", 1)[1] if ":secret:" in ident else ident
        secret = backend.secrets.get(name)
        if secret is not None:
            return secret
        for candidate in backend.secrets.values():
            arn = getattr(candidate, "arn", "") or ""
            if arn == ident or getattr(candidate, "name", None) == name:
                return candidate
            if ident.startswith("arn:") and arn.startswith(ident + "-"):
                return candidate
    except Exception as exc:
        LOG.debug("secretsmanager lookup failed for %s: %s", ident, exc)
    return None


def load_secretsmanager_policy_doc(
    ident: str, account_id: str, region: str,
) -> dict | None:
    secret = find_secret(account_id, region, ident)
    if secret is None:
        return None
    return _parse_policy(getattr(secret, "policy", None))


def canonical_secret_arn(ident: str | None, account_id: str, region: str) -> str | None:
    if not ident:
        return None
    secret = find_secret(account_id, region, ident)
    if secret is None:
        return None
    arn = getattr(secret, "arn", None)
    return arn if isinstance(arn, str) and arn else None


def secret_customer_kms_key(ident: str, account_id: str, region: str) -> str | None:
    secret = find_secret(account_id, region, ident)
    if secret is None:
        return None
    return _customer_managed_key(getattr(secret, "kms_key_id", None))


def _native_kms_key(key_ref: str, account_id: str, region: str):
    """Return ``(key, account, region, key_id)`` from LocalEmu's KMS store."""
    if key_ref.startswith("arn:"):
        parts = key_ref.split(":")
        if len(parts) >= 5:
            if parts[3]:
                region = parts[3]
            if parts[4]:
                account_id = parts[4]
    try:
        from localemu.services.kms.models import kms_stores

        store = kms_stores[account_id][region]
        if ":alias/" in key_ref or key_ref.startswith("alias/"):
            alias = key_ref if key_ref.startswith("alias/") else "alias/" + key_ref.split(":alias/", 1)[1]
            found = store.aliases.get(alias)
            if found is None:
                return None
            key_id = (found.metadata or {}).get("TargetKeyId")
        elif ":key/" in key_ref:
            key_id = key_ref.split(":key/", 1)[1]
        elif key_ref.startswith("arn:"):
            return None
        else:
            key_id = key_ref
        if not key_id:
            return None
        key = store.keys.get(key_id)
        if key is None:
            return None
        return key, account_id, region, key_id
    except Exception as exc:
        LOG.debug("kms key lookup failed for %s: %s", key_ref, exc)
        return None


def canonical_kms_arn(key_ref: str | None, account_id: str, region: str) -> str | None:
    if not key_ref or not isinstance(key_ref, str):
        return None
    found = _native_kms_key(key_ref, account_id, region)
    if not found:
        return None
    key, account_id, region, key_id = found
    arn = (getattr(key, "metadata", None) or {}).get("Arn")
    if isinstance(arn, str) and arn:
        return arn
    return f"arn:aws:kms:{region}:{account_id}:key/{key_id}"


def load_kms_key_policy(key_ref: str | None, account_id: str, region: str) -> dict | None:
    if not key_ref:
        return None
    found = _native_kms_key(key_ref, account_id, region)
    if not found:
        return None
    return _parse_policy(getattr(found[0], "policy", None))


def key_id_from_ciphertext(blob: Any) -> str | None:
    """Pull the moto key id out of a Decrypt ciphertext blob."""
    if blob is None:
        return None
    raw = blob
    if isinstance(blob, str):
        import base64
        try:
            raw = base64.b64decode(blob)
        except Exception:
            return None
    if isinstance(raw, bytearray):
        raw = bytes(raw)
    if not isinstance(raw, bytes):
        return None
    try:
        from moto.kms.utils import _deserialize_ciphertext_blob

        key_id = _deserialize_ciphertext_blob(raw).key_id
        if isinstance(key_id, bytes):
            key_id = key_id.decode("utf-8", "ignore")
        key_id = str(key_id).strip("\x00").strip()
        return key_id or None
    except Exception:
        return None


def s3_bucket_owner(bucket_name: str, caller_account: str) -> str | None:
    if not bucket_name or bucket_name == "*":
        return None
    try:
        from localemu.constants import AWS_REGION_US_EAST_1
        from localemu.services.s3.models import s3_stores

        store = s3_stores[caller_account][AWS_REGION_US_EAST_1]
        if bucket_name in store.buckets:
            return caller_account
        owner = store.global_bucket_map.get(bucket_name) if hasattr(store, "global_bucket_map") else None
        return owner or None
    except Exception as exc:
        LOG.debug("s3 owner lookup failed for %s: %s", bucket_name, exc)
        return None


def resource_owner_account(
    action: str, resource_arn: str, caller_account: str, region: str,
) -> str:
    """Account that owns the resource, falling back to the caller when unknown."""
    del region
    service = action.split(":", 1)[0] if action else ""
    if service == "s3" and ":::" in resource_arn:
        owner = s3_bucket_owner(resource_arn.split(":::")[-1].split("/")[0], caller_account)
        if owner:
            return owner
    if resource_arn.startswith("arn:"):
        parts = resource_arn.split(":")
        if len(parts) >= 5 and len(parts[4]) == 12 and parts[4].isdigit():
            return parts[4]
    return caller_account


def _statement_list(policy: dict | None) -> list:
    if not isinstance(policy, dict):
        return []
    try:
        from localemu.utils.aws.policy import iter_policy_statements

        return [st for st in iter_policy_statements(policy) if isinstance(st, dict)]
    except Exception:
        statements = policy.get("Statement") or []
        if isinstance(statements, dict):
            return [statements]
        if isinstance(statements, list):
            return [st for st in statements if isinstance(st, dict)]
        return []


def _merged_context(caller, conditions: dict | None) -> dict:
    merged = dict(conditions or {})
    tags = getattr(caller, "tags", None) or {}
    if isinstance(tags, dict):
        merged.update(tags)
    return merged


def _canonical_condition_keys(statement: dict, ctx: dict) -> dict:
    """Condition keys are case-insensitive; Lambda stores ``AWS:SourceArn``."""
    condition = statement.get("Condition")
    if not isinstance(condition, dict):
        return statement
    by_lower = {str(k).lower(): k for k in ctx}
    renamed = {}
    for operator, pairs in condition.items():
        if isinstance(pairs, dict):
            pairs = {by_lower.get(str(k).lower(), k): v for k, v in pairs.items()}
        renamed[operator] = pairs
    return {**statement, "Condition": renamed}


def _statement_matches_action_resource(statement: dict, action: str, resource: str, ctx: dict) -> bool:
    from localemu.services.iam_enforcement.action_matcher import matches_action
    from localemu.services.iam_enforcement.condition_evaluator import matches_conditions
    from localemu.services.iam_enforcement.resource_matcher import matches_resource

    statement = _canonical_condition_keys(statement, ctx)
    if not matches_action(statement, action):
        return False
    if not matches_resource(statement, resource, ctx):
        return False
    return matches_conditions(statement, ctx)


def resource_policy_effect(policy: dict | None, caller, action: str, resource: str, conditions: dict | None) -> str:
    """``deny``, ``allow``, or ``neutral`` for a resource policy against this caller."""
    from localemu.services.iam_enforcement.evaluator import _matches_principal

    ctx = _merged_context(caller, conditions)
    saw_allow = False
    for statement in _statement_list(policy):
        effect = statement.get("Effect")
        if effect not in ("Allow", "Deny"):
            continue
        if not _statement_matches_action_resource(statement, action, resource, ctx):
            continue
        if not _matches_principal(statement, caller):
            continue
        if effect == "Deny":
            return "deny"
        saw_allow = True
    return "allow" if saw_allow else "neutral"


def _caller_role_arn(caller) -> str | None:
    if getattr(caller, "principal_type", None) == "AssumedRole" and getattr(caller, "role_name", None):
        return f"arn:aws:iam::{caller.account_id}:role/{caller.role_name}"
    return _role_arn_from_assumed_session(getattr(caller, "arn", "") or "")


def _is_account_principal(value: str, account_id: str) -> bool:
    return value == account_id or value == f"arn:aws:iam::{account_id}:root"


def _is_direct_principal(value: str, caller) -> bool:
    if value == "*" or value == getattr(caller, "arn", None):
        return True
    role_arn = _caller_role_arn(caller)
    return bool(role_arn and value == role_arn)


def _aws_principal_values(statement: dict) -> list[str] | None:
    """AWS principal strings, or None when the statement does not name one.

    Account-root is reported as the raw string so callers can tell delegation
    from a grant to a specific role or user.
    """
    principal = statement.get("Principal")
    if principal == "*":
        return ["*"]
    if not isinstance(principal, dict) or statement.get("NotPrincipal"):
        return None
    aws_p = principal.get("AWS")
    if isinstance(aws_p, str):
        return [aws_p]
    if isinstance(aws_p, list):
        return [str(item) for item in aws_p]
    return None


def kms_key_policy_view(policy: dict | None, caller, action: str, resource: str, conditions: dict | None) -> str:
    """Classify the key policy for this caller and action.

    Returns ``deny``, ``direct`` (policy names the caller), ``delegate``
    (policy Allows the caller's account root, which enables IAM), or ``none``.
    """
    ctx = _merged_context(caller, conditions)
    saw_direct = False
    saw_delegate = False
    for statement in _statement_list(policy):
        effect = statement.get("Effect")
        if effect not in ("Allow", "Deny"):
            continue
        if not _statement_matches_action_resource(statement, action, resource, ctx):
            continue
        values = _aws_principal_values(statement)
        if not values:
            continue
        matches_caller = any(
            _is_direct_principal(value, caller) or _is_account_principal(value, caller.account_id)
            for value in values
        )
        if effect == "Deny" and matches_caller:
            return "deny"
        if effect != "Allow":
            continue
        if any(_is_direct_principal(value, caller) for value in values):
            saw_direct = True
        elif any(_is_account_principal(value, caller.account_id) for value in values):
            saw_delegate = True
    if saw_direct:
        return "direct"
    if saw_delegate:
        return "delegate"
    return "none"


def evaluate_kms_crypto(orig_evaluate, evaluator, caller, action: str, resource: str, conditions: dict | None, resource_policy: dict | None):
    """KMS key-policy rules on top of the identity evaluator.

    Same account: a direct key-policy Allow is enough. Otherwise the key
    policy must delegate to the account and an identity policy must Allow.
    Cross account: both the key policy (direct or that account's root) and
    the caller's identity policy must Allow.
    """
    from localemu.services.iam_enforcement.evaluator import Decision

    identity = orig_evaluate(evaluator, caller, action, resource, conditions, None)
    if identity == Decision.EXPLICIT_DENY:
        return identity
    view = kms_key_policy_view(resource_policy, caller, action, resource, conditions)
    if view == "deny":
        return Decision.EXPLICIT_DENY
    region = (conditions or {}).get("aws:RequestedRegion") or "us-east-1"
    owner = resource_owner_account(action, resource, caller.account_id, region)
    cross = owner != caller.account_id
    if view == "direct" and not cross:
        return Decision.ALLOW
    if identity == Decision.ALLOW and view in ("direct", "delegate"):
        return Decision.ALLOW
    return Decision.IMPLICIT_DENY


def evaluate_both_required(orig_evaluate, evaluator, caller, action: str, resource: str, conditions: dict | None, resource_policy: dict | None):
    """Cross-account rule: explicit deny wins; both sides must Allow."""
    from localemu.services.iam_enforcement.evaluator import Decision

    identity = orig_evaluate(evaluator, caller, action, resource, conditions, None)
    if identity == Decision.EXPLICIT_DENY:
        return identity
    effect = resource_policy_effect(resource_policy, caller, action, resource, conditions)
    if effect == "deny":
        return Decision.EXPLICIT_DENY
    if identity == Decision.ALLOW and effect == "allow":
        return Decision.ALLOW
    return Decision.IMPLICIT_DENY


# --------------------------------------------------------------------------
# Service-principal delivery (SNS → SQS, …)
# --------------------------------------------------------------------------


def normalize_service_principal(value: str | None) -> str | None:
    """Map ``sns`` / ``sns.amazonaws.com`` to the full service principal."""
    if not value or not isinstance(value, str):
        return None
    sp = value.strip()
    if not sp:
        return None
    if "." not in sp:
        return f"{sp}.amazonaws.com"
    return sp


def service_delivery_context(source_arn: str | None, region: str) -> dict:
    """Condition keys SNS (and friends) present on the wire to the target."""
    ctx: dict[str, str] = {
        "aws:RequestedRegion": region or "us-east-1",
    }
    if source_arn and isinstance(source_arn, str):
        ctx["aws:SourceArn"] = source_arn
        parts = source_arn.split(":")
        if len(parts) >= 5 and parts[4]:
            ctx["aws:SourceAccount"] = parts[4]
            ctx["aws:PrincipalAccount"] = parts[4]
    return ctx


def service_caller(service_principal: str, account_id: str):
    """Synthetic caller for ``Principal: {Service: …}`` resource-policy grants."""
    from localemu.services.iam_enforcement.identity import CallerIdentity

    return CallerIdentity(
        principal_type="Service",
        account_id=account_id,
        arn=service_principal,
        acting_services=[service_principal],
    )


def evaluate_service_delivery(
    service_principal: str,
    action: str,
    resource_arn: str,
    resource_policy: dict | None,
    source_arn: str | None,
    account_id: str,
    region: str,
) -> str:
    """``allow`` / ``deny`` / ``neutral`` for a service→resource delivery.

    Real AWS only delivers when the target resource policy Allows the service
    principal (typically with ``aws:SourceArn``). No document → not allowed.
    Identity policies do not apply to service principals.
    """
    if not resource_policy:
        return "neutral"
    caller = service_caller(service_principal, account_id)
    conditions = service_delivery_context(source_arn, region)
    return resource_policy_effect(
        resource_policy, caller, action, resource_arn, conditions,
    )


def _sqs_queue_from_arn(queue_arn: str):
    """Resolve a native LocalEmu SQS queue object from its ARN, or None."""
    if not queue_arn or not isinstance(queue_arn, str) or not queue_arn.startswith("arn:"):
        return None
    parts = queue_arn.split(":")
    if len(parts) < 6:
        return None
    region = parts[3] or "us-east-1"
    account_id = parts[4] or "000000000000"
    queue_name = parts[5]
    if not queue_name:
        return None
    try:
        from localemu.services.sqs.models import sqs_stores

        store = sqs_stores[account_id][region]
        queues = getattr(store, "queues", None) or {}
        queue = queues.get(queue_name) if isinstance(queues, dict) else None
        if queue is not None:
            return queue
        for candidate in (queues.values() if isinstance(queues, dict) else queues):
            if getattr(candidate, "arn", None) == queue_arn:
                return candidate
            name = getattr(candidate, "name", None) or getattr(candidate, "queue_name", None)
            if name == queue_name:
                return candidate
    except Exception as exc:
        LOG.debug("SQS queue lookup failed for %s: %s", queue_arn, exc)
    return None


def sqs_queue_kms_master_key_id(queue_arn: str) -> str | None:
    """``KmsMasterKeyId`` on the queue, or None when unset / SQS-managed SSE only."""
    queue = _sqs_queue_from_arn(queue_arn)
    if queue is None:
        return None
    attrs = getattr(queue, "attributes", None) or {}
    raw = attrs.get("KmsMasterKeyId")
    if raw is None:
        return None
    key = str(raw).strip()
    return key or None


def is_aws_managed_sqs_kms_key(key_id: str | None) -> bool:
    """True for ``alias/aws/sqs`` (policy cannot grant sns.amazonaws.com)."""
    if not key_id or not isinstance(key_id, str):
        return False
    ref = key_id.strip()
    if not ref:
        return False
    if ref == "alias/aws/sqs":
        return True
    # Full alias ARN: arn:aws:kms:region:account:alias/aws/sqs
    return ref.endswith(":alias/aws/sqs") or ":alias/aws/sqs" in ref


def sns_blocked_by_sqs_aws_managed_kms(queue_arn: str) -> bool:
    """AWS cannot deliver SNS→SQS when the queue uses ``alias/aws/sqs``.

    The AWS-managed SQS key policy is not editable, so SNS never gets
    ``kms:GenerateDataKey`` / ``kms:Decrypt``. SQS-managed SSE
    (``SqsManagedSseEnabled``) is not blocked here. Customer CMKs are
    evaluated by ``sns_blocked_by_sqs_cmk_policy``.
    """
    return is_aws_managed_sqs_kms_key(sqs_queue_kms_master_key_id(queue_arn))


def sns_blocked_by_sqs_cmk_policy(queue_arn: str, topic_arn: str) -> bool:
    """True when the queue CMK does not Allow ``sns.amazonaws.com``.

    Both ``kms:GenerateDataKey`` and ``kms:Decrypt`` must be allowed
    (``kms:GenerateDataKey*`` and ``kms:*`` count). No ``KmsMasterKeyId``
    and ``alias/aws/*`` are not customer CMKs. A missing key or a policy
    that does not Allow both actions blocks delivery. Account-root
    delegation does not grant the SNS service principal.
    """
    customer = _customer_managed_key(sqs_queue_kms_master_key_id(queue_arn))
    if not customer:
        return False
    parts = queue_arn.split(":") if isinstance(queue_arn, str) else []
    region = parts[3] if len(parts) > 3 and parts[3] else "us-east-1"
    account_id = parts[4] if len(parts) > 4 and parts[4] else "000000000000"
    policy = load_kms_key_policy(customer, account_id, region)
    key_arn = canonical_kms_arn(customer, account_id, region) or customer
    # Account-root Allow is IAM delegation, not a grant to sns.amazonaws.com.
    # The principal matcher treats :root as every caller in that account, so
    # pass no account id and only Principal.Service / "*" can match.
    for action in ("kms:GenerateDataKey", "kms:Decrypt"):
        effect = evaluate_service_delivery(
            "sns.amazonaws.com",
            action,
            key_arn,
            policy,
            topic_arn,
            "",
            region,
        )
        if effect != "allow":
            return True
    return False


def _truthy(value: Any) -> bool:
    if isinstance(value, str):
        return value.lower() == "true"
    return bool(value)


def _s3_bucket(bucket_name: str, account_id: str, region: str):
    """Resolve a LocalEmu S3 bucket (cross-region map lives on us-east-1)."""
    if not bucket_name:
        return None
    try:
        from localemu.constants import AWS_REGION_US_EAST_1
        from localemu.services.s3.models import s3_stores

        del region
        store = s3_stores[account_id][AWS_REGION_US_EAST_1]
        bucket = store.buckets.get(bucket_name)
        if bucket is not None:
            return bucket
        owner = store.global_bucket_map.get(bucket_name) if hasattr(store, "global_bucket_map") else None
        if owner:
            return s3_stores[owner][AWS_REGION_US_EAST_1].buckets.get(bucket_name)
    except Exception as exc:
        LOG.debug("s3 bucket lookup failed for %s: %s", bucket_name, exc)
    return None


def _s3_write_customer_kms_key(params: dict, account_id: str, region: str) -> str | None:
    """CMK used when S3 writes with SSE-KMS (request or bucket default)."""
    encryption = params.get("ServerSideEncryption")
    key_id = params.get("SSEKMSKeyId")
    bucket = _s3_bucket(str(params.get("Bucket") or ""), account_id, region)
    rule = getattr(bucket, "encryption_rule", None) if bucket is not None else None
    if isinstance(rule, dict):
        default = rule.get("ApplyServerSideEncryptionByDefault") or {}
        if isinstance(default, dict):
            encryption = encryption or default.get("SSEAlgorithm")
            if not key_id and encryption in ("aws:kms", "aws:kms:dsse"):
                key_id = default.get("KMSMasterKeyID")
    if encryption not in ("aws:kms", "aws:kms:dsse") and not key_id:
        return None
    return _customer_managed_key(key_id if isinstance(key_id, str) else None)


def _s3_object_customer_kms_key(
    bucket_name: str, object_key: str, version_id: str | None, account_id: str, region: str
) -> str | None:
    """CMK on an existing object (GetObject / HeadObject SSE-KMS path)."""
    bucket = _s3_bucket(bucket_name, account_id, region)
    if bucket is None:
        return None
    try:
        s3_object = bucket.get_object(key=object_key, version_id=version_id, http_method="GET")
    except Exception as exc:
        LOG.debug("s3 object lookup failed for %s/%s: %s", bucket_name, object_key, exc)
        return None
    return _customer_managed_key(getattr(s3_object, "kms_key_id", None))


def s3_via_service(region: str) -> str:
    """``kms:ViaService`` value AWS sets for S3-mediated KMS calls."""
    return f"s3.{region or 'us-east-1'}.amazonaws.com"


def service_origin_kms_context(source_arn: str | None, account_id: str, region: str) -> dict[str, str]:
    """Condition keys S3 (and friends) present on mediated KMS calls (#223)."""
    ctx: dict[str, str] = {
        "kms:ViaService": s3_via_service(region),
        "aws:SourceAccount": account_id,
    }
    if source_arn:
        ctx["aws:SourceArn"] = source_arn
    return ctx


def implicit_kms_checks(service: str, operation: str, params: dict | None, account_id: str, region: str) -> list[tuple[str, str]]:
    """Customer-managed keys touched implicitly by Secrets Manager or SSM.

    Each pair is ``(kms_action, key_id)``. AWS-managed ``alias/aws/*`` keys
    are omitted; the service uses those on the caller's behalf.
    """
    params = params or {}
    checks: list[tuple[str, str]] = []

    def add(action: str, key_id: str | None) -> None:
        customer = _customer_managed_key(key_id)
        if customer:
            checks.append((action, customer))

    if service == "secretsmanager":
        secret_id = params.get("SecretId") or params.get("Name") or ""
        if operation == "GetSecretValue":
            add("kms:Decrypt", secret_customer_kms_key(str(secret_id), account_id, region))
        elif operation in ("PutSecretValue", "UpdateSecret"):
            add("kms:GenerateDataKey", secret_customer_kms_key(str(secret_id), account_id, region))
            if operation == "UpdateSecret":
                add("kms:GenerateDataKey", params.get("KmsKeyId"))
        elif operation == "CreateSecret":
            add("kms:GenerateDataKey", params.get("KmsKeyId"))
        return checks

    if service != "ssm":
        return checks

    if operation == "PutParameter" and params.get("Type") == "SecureString":
        add("kms:Encrypt", params.get("KeyId"))
        return checks

    if operation not in ("GetParameter", "GetParameters", "GetParametersByPath"):
        return checks
    if not _truthy(params.get("WithDecryption")):
        return checks

    names: list[str] = []
    if operation == "GetParameter" and params.get("Name"):
        names = [str(params["Name"])]
    elif operation == "GetParameters":
        raw_names = params.get("Names") or []
        if isinstance(raw_names, list):
            names = [str(name) for name in raw_names]
    elif operation == "GetParametersByPath" and params.get("Path"):
        names = _ssm_names_by_path(
            str(params["Path"]),
            _truthy(params.get("Recursive")),
            account_id,
            region,
        )
    for name in names:
        add("kms:Decrypt", _ssm_parameter_key(name, account_id, region))
    return checks


def implicit_s3_kms_checks(
    operation: str, params: dict | None, account_id: str, region: str
) -> list[tuple[str, str, str]]:
    """S3 SSE-KMS → KMS checks with bucket ARN for service-origin keys (#223).

    Each triple is ``(kms_action, key_id, bucket_arn)``. AWS-managed
    ``alias/aws/s3`` keys are omitted.
    """
    params = params or {}
    bucket_name = params.get("Bucket")
    if not isinstance(bucket_name, str) or not bucket_name:
        return []
    bucket_arn = f"arn:aws:s3:::{bucket_name}"
    out: list[tuple[str, str, str]] = []

    write_ops = {"PutObject", "CreateMultipartUpload", "UploadPart", "CopyObject"}
    read_ops = {"GetObject", "HeadObject", "CopyObject"}

    if operation in write_ops:
        # CopyObject dest uses DestinationBucket when present.
        dest_bucket = params.get("Bucket")
        if operation == "CopyObject" and params.get("DestinationBucket"):
            dest_bucket = params.get("DestinationBucket")
        if isinstance(dest_bucket, str) and dest_bucket:
            dest_params = dict(params)
            dest_params["Bucket"] = dest_bucket
            key_id = _s3_write_customer_kms_key(dest_params, account_id, region)
            if key_id:
                out.append(("kms:GenerateDataKey", key_id, f"arn:aws:s3:::{dest_bucket}"))

    if operation in read_ops:
        object_key = params.get("Key")
        if operation == "CopyObject":
            # Source is CopySource = "bucket/key" or {Bucket, Key}.
            copy_source = params.get("CopySource")
            src_bucket = None
            src_key = None
            if isinstance(copy_source, str) and "/" in copy_source:
                src_bucket, src_key = copy_source.split("/", 1)
                src_key = src_key.split("?", 1)[0]
            elif isinstance(copy_source, dict):
                src_bucket = copy_source.get("Bucket")
                src_key = copy_source.get("Key")
            if isinstance(src_bucket, str) and isinstance(src_key, str):
                key_id = _s3_object_customer_kms_key(
                    src_bucket, src_key, None, account_id, region
                )
                if key_id:
                    out.append(("kms:Decrypt", key_id, f"arn:aws:s3:::{src_bucket}"))
        elif isinstance(object_key, str) and object_key:
            version_id = params.get("VersionId")
            version = version_id if isinstance(version_id, str) else None
            key_id = _s3_object_customer_kms_key(
                bucket_name, object_key, version, account_id, region
            )
            if key_id:
                out.append(("kms:Decrypt", key_id, bucket_arn))

    return out


def _ssm_parameter_key(name: str, account_id: str, region: str) -> str | None:
    try:
        from moto.ssm.models import ssm_backends

        param = ssm_backends[account_id][region].get_parameter(name)
    except Exception as exc:
        LOG.debug("ssm parameter lookup failed for %s: %s", name, exc)
        return None
    if param is None or getattr(param, "parameter_type", None) != "SecureString":
        return None
    return getattr(param, "keyid", None)


def _ssm_names_by_path(path: str, recursive: bool, account_id: str, region: str) -> list[str]:
    try:
        from moto.ssm.models import ssm_backends

        backend = ssm_backends[account_id][region]
        names: list[str] = []
        token: str | None = None
        for _ in range(10):
            page, token = backend.get_parameters_by_path(
                path, recursive, next_token=token, max_results=10,
            )
            names.extend(param.name for param in page)
            if not token:
                break
        return names
    except Exception as exc:
        LOG.debug("ssm path lookup failed for %s: %s", path, exc)
        return []

def load_dynamodb_resource_policy(
    resource_arn: str, account_id: str, region: str,
) -> dict | None:
    """Load a DynamoDB table resource policy from moto (#516).

    Policies are stored under the table ARN by ``PutResourcePolicy``. Index
    ARNs (``…/index/…``) inherit the table document.
    """
    if not resource_arn or not isinstance(resource_arn, str):
        return None
    table_arn = resource_arn.split("/index/", 1)[0]
    try:
        import moto.backends as moto_backends

        backend = moto_backends.get_backend("dynamodb")[account_id][region]
        policies = getattr(backend, "resource_policies", None) or {}
        policy = policies.get(table_arn) or policies.get(resource_arn)
        if policy is None and policies:
            # ARN account/region drift: match by table name suffix.
            table_name = table_arn.rsplit("/", 1)[-1]
            for key, candidate in policies.items():
                if isinstance(key, str) and key.endswith(f"/{table_name}"):
                    policy = candidate
                    break
        if policy is None:
            return None
        return _parse_policy(getattr(policy, "policy_doc", None))
    except Exception as exc:
        LOG.debug(
            "dynamodb resource policy load failed for %s: %s", resource_arn, exc,
        )
        return None

