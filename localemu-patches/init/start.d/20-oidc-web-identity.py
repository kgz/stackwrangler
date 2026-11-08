"""OIDC web-identity trust conditions and iam:PassRole / iam:PassedToService (#209)."""

from __future__ import annotations

import contextvars
import json
import logging
import re
import time
import urllib.error
import urllib.request

LOG = logging.getLogger("localemu.awsbox.oidc")

_OIDC_STATE: contextvars.ContextVar[tuple | None] = contextvars.ContextVar(
    "awsbox_oidc_state", default=None
)
_JWKS_CACHE: dict[str, tuple[float, dict]] = {}
_TEST_JWKS_PATHS = (
    "/opt/awsbox/oidc/jwks.json",
    "/etc/localemu/init/start.d/oidc/jwks.json",
)
_ROLE_ARN_RE = re.compile(r"^arn:[^:]+:iam::[^:]+:role/.+")
# Service id on the request -> principal AWS puts in iam:PassedToService.
_PASSED_TO_SERVICE = {
    "lambda": "lambda.amazonaws.com",
    "ecs": "ecs-tasks.amazonaws.com",
    "ec2": "ec2.amazonaws.com",
    "events": "events.amazonaws.com",
    "states": "states.amazonaws.com",
    "stepfunctions": "states.amazonaws.com",
    "logs": "logs.amazonaws.com",
    "transfer": "transfer.amazonaws.com",
    "rds": "rds.amazonaws.com",
    "apigateway": "apigateway.amazonaws.com",
    "apigatewayv2": "apigateway.amazonaws.com",
    "scheduler": "scheduler.amazonaws.com",
    "sns": "sns.amazonaws.com",
    "sqs": "sqs.amazonaws.com",
    "kinesis": "kinesis.amazonaws.com",
    "firehose": "firehose.amazonaws.com",
    "batch": "batch.amazonaws.com",
    "cloudformation": "cloudformation.amazonaws.com",
}


def _invalid_token(message: str):
    from localemu.aws.api import CommonServiceException

    return CommonServiceException(
        code="InvalidIdentityToken", message=message, status_code=400, sender_fault=True
    )


def _normalize_issuer(iss: str) -> str:
    text = (iss or "").strip()
    for prefix in ("https://", "http://"):
        if text.lower().startswith(prefix):
            text = text[len(prefix) :]
            break
    return text.rstrip("/")


def _load_test_jwks() -> dict:
    for path in _TEST_JWKS_PATHS:
        try:
            with open(path, encoding="utf-8") as fh:
                return json.load(fh)
        except OSError:
            continue
    raise _invalid_token("Local test JWKS is not mounted")


def _http_json(url: str) -> dict | None:
    if not url.startswith(("https://", "http://")):
        return None
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=2) as resp:
            body = resp.read()
    except (urllib.error.URLError, TimeoutError, OSError, ValueError):
        return None
    try:
        parsed = json.loads(body.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        return None
    return parsed if isinstance(parsed, dict) else None


def _fetch_jwks(provider_url: str) -> dict:
    cached = _JWKS_CACHE.get(provider_url)
    now = time.time()
    if cached and now - cached[0] < 300:
        return cached[1]
    discovery = _http_json(f"https://{provider_url}/.well-known/openid-configuration")
    jwks = None
    if discovery and isinstance(discovery.get("jwks_uri"), str):
        jwks = _http_json(discovery["jwks_uri"])
    if not jwks:
        jwks = _http_json(f"https://{provider_url}/.well-known/jwks.json")
    if not jwks:
        jwks = _http_json(f"http://{provider_url}/.well-known/jwks.json")
    if not jwks or not isinstance(jwks.get("keys"), list):
        raise _invalid_token(f"Unable to load JWKS for {provider_url}")
    _JWKS_CACHE[provider_url] = (now, jwks)
    return jwks


def _jwks_for(provider) -> dict:
    host = provider.url.split("/")[0]
    if host == "awsbox.local":
        return _load_test_jwks()
    return _fetch_jwks(provider.url.rstrip("/"))


def _select_key(jwks: dict, kid: str | None):
    import jwt

    chosen = None
    for jwk in jwks.get("keys") or []:
        if not isinstance(jwk, dict):
            continue
        if kid and jwk.get("kid") and jwk.get("kid") != kid:
            continue
        chosen = jwk
        break
    if not chosen:
        return None
    return jwt.PyJWK.from_dict(chosen).key


def _find_provider(account_id: str, iss: str):
    from moto.iam.models import iam_backends

    wanted = _normalize_issuer(iss)
    try:
        backend = iam_backends[account_id]["global"]
    except Exception:
        return None
    for provider in getattr(backend, "open_id_providers", {}).values():
        if provider.url.rstrip("/") == wanted:
            return provider
    return None


def _verify_and_set(role_arn: str, token: str) -> None:
    import jwt
    from localemu.utils.aws.arns import extract_account_id_from_arn

    if not token or token.count(".") != 2:
        raise _invalid_token("Token must be a JWT")
    try:
        header = jwt.get_unverified_header(token)
    except Exception as exc:
        raise _invalid_token("Token is not a valid JWT") from exc
    if header.get("alg") != "RS256":
        raise _invalid_token("Token algorithm must be RS256")
    try:
        unverified = jwt.decode(token, options={"verify_signature": False})
    except Exception as exc:
        raise _invalid_token("Token payload is not valid JSON") from exc
    iss = str(unverified.get("iss") or "")
    account_id = extract_account_id_from_arn(role_arn) or "000000000000"
    provider = _find_provider(account_id, iss)
    if provider is None:
        raise _invalid_token(f"No OpenIDConnect provider found for {iss}")
    if _normalize_issuer(iss) != provider.url.rstrip("/"):
        raise _invalid_token("Token issuer does not match the provider URL")
    key = _select_key(_jwks_for(provider), header.get("kid"))
    if key is None:
        raise _invalid_token("No matching JWK for token")
    client_ids = [str(item) for item in (provider.client_id_list or [])]
    if not client_ids:
        raise _invalid_token("OpenIDConnect provider has no client ids")
    try:
        claims = jwt.decode(
            token,
            key,
            algorithms=["RS256"],
            audience=client_ids,
            leeway=30,
            options={"require": ["exp", "iss", "sub", "aud"]},
        )
    except jwt.ExpiredSignatureError as exc:
        raise _invalid_token("Token is expired") from exc
    except jwt.InvalidAudienceError as exc:
        raise _invalid_token("Token audience is not a registered client id") from exc
    except Exception as exc:
        raise _invalid_token("Token signature is invalid") from exc
    _OIDC_STATE.set((claims, provider))


def _condition_context(provider, claims: dict) -> dict:
    prefix = provider.url.rstrip("/")
    ctx: dict = {}
    for key, value in claims.items():
        if key in ("exp", "nbf", "iat"):
            continue
        cond_key = f"{prefix}:{key}"
        if isinstance(value, str):
            ctx[cond_key] = value
        elif isinstance(value, bool):
            ctx[cond_key] = "true" if value else "false"
        elif isinstance(value, list) and value and all(isinstance(item, str) for item in value):
            ctx[cond_key] = value[0] if len(value) == 1 else value
    return ctx


def _federated_matches(principal_value: str, provider) -> bool:
    if principal_value in ("*", provider.arn, provider.url):
        return True
    bare = provider.url.rstrip("/")
    return principal_value.rstrip("/") in {
        bare,
        f"https://{bare}",
        f"http://{bare}",
    }


def _statement_matches(statement: dict, provider, claims: dict) -> bool:
    from localemu.services.iam_enforcement.condition_evaluator import matches_conditions

    effect = (statement.get("Effect") or "").lower()
    if effect != "allow":
        return False
    action = statement.get("Action") or []
    if isinstance(action, str):
        action = [action]
    if not any(item in ("sts:AssumeRoleWithWebIdentity", "sts:*", "*") for item in action):
        return False
    principal = statement.get("Principal")
    if principal == "*":
        matched = True
    elif isinstance(principal, dict):
        fed = principal.get("Federated") or []
        if isinstance(fed, str):
            fed = [fed]
        matched = any(_federated_matches(item, provider) for item in fed)
    else:
        matched = False
    if not matched:
        return False
    return matches_conditions(statement, _condition_context(provider, claims))


def _patch_sts() -> None:
    from localemu.services.sts import provider as sts_provider
    from localemu.services.sts.provider import StsProvider

    original_trust = sts_provider._trust_policy_allows_web_identity
    original_assume = StsProvider.assume_role_with_web_identity

    def _trust_policy_allows_web_identity(role, issuer: str) -> bool:
        state = _OIDC_STATE.get()
        if not state:
            return original_trust(role, issuer)
        claims, provider = state
        trust_doc_str = getattr(role, "assume_role_policy_document", None)
        if not trust_doc_str:
            return False
        try:
            trust_doc = (
                json.loads(trust_doc_str) if isinstance(trust_doc_str, str) else trust_doc_str
            )
        except (json.JSONDecodeError, TypeError):
            return False
        statements = trust_doc.get("Statement") or []
        if isinstance(statements, dict):
            statements = [statements]
        if not isinstance(statements, list):
            return False
        for statement in statements:
            if isinstance(statement, dict) and _statement_matches(statement, provider, claims):
                return True
        return False

    def assume_role_with_web_identity(
        self, context, role_arn, role_session_name, web_identity_token, *args, **kwargs
    ):
        _verify_and_set(role_arn, web_identity_token)
        try:
            return original_assume(
                self,
                context,
                role_arn,
                role_session_name,
                web_identity_token,
                *args,
                **kwargs,
            )
        finally:
            _OIDC_STATE.set(None)

    sts_provider._trust_policy_allows_web_identity = _trust_policy_allows_web_identity
    StsProvider.assume_role_with_web_identity = assume_role_with_web_identity


def _is_role_field(key: str) -> bool:
    leaf = str(key).replace("_", "").split(".")[-1].lower()
    return leaf in ("role", "accessrole", "loggingrole") or leaf.endswith("rolearn")


def _is_instance_profile_field(key: str) -> bool:
    leaf = str(key).replace("_", "").split(".")[-1].lower()
    return leaf in (
        "iaminstanceprofile",
        "iaminstanceprofilename",
        "iaminstanceprofilearn",
        "instanceprofile",
        "instanceprofilename",
        "instanceprofilearn",
    )


def _collect_passed_roles(node, found: list[str]) -> None:
    if isinstance(node, dict):
        for key, value in node.items():
            if _is_role_field(key) and isinstance(value, str) and _ROLE_ARN_RE.match(value):
                found.append(value)
            else:
                _collect_passed_roles(value, found)
    elif isinstance(node, list):
        for item in node:
            _collect_passed_roles(item, found)


def _collect_instance_profile_refs(node, found: list[str]) -> None:
    """Gather IamInstanceProfile Name/Arn values (EC2 PassRole path, #223)."""
    if isinstance(node, dict):
        for key, value in node.items():
            if _is_instance_profile_field(key):
                if isinstance(value, dict):
                    arn = value.get("Arn") or value.get("arn")
                    name = value.get("Name") or value.get("name")
                    if isinstance(arn, str) and arn:
                        found.append(arn)
                    elif isinstance(name, str) and name:
                        found.append(name)
                elif isinstance(value, str) and value:
                    found.append(value)
            else:
                _collect_instance_profile_refs(value, found)
    elif isinstance(node, list):
        for item in node:
            _collect_instance_profile_refs(item, found)


def _roles_from_instance_profiles(refs: list[str], account_id: str) -> list[str]:
    """Resolve instance-profile refs to the role ARNs AWS treats as PassRole."""
    if not refs:
        return []
    try:
        from moto.iam.models import iam_backends

        backend = iam_backends[account_id]["global"]
    except Exception:
        LOG.debug("iam backend unavailable for instance-profile PassRole", exc_info=True)
        return []
    roles: list[str] = []
    for ref in refs:
        try:
            if ref.startswith("arn:"):
                profile = backend.get_instance_profile_by_arn(ref)
            else:
                profile = backend.get_instance_profile(ref)
        except Exception:
            LOG.debug("instance profile lookup failed for %s", ref, exc_info=True)
            continue
        for role in getattr(profile, "roles", None) or []:
            arn = getattr(role, "arn", None)
            if isinstance(arn, str) and arn:
                roles.append(arn)
    return roles


def _patch_pass_role() -> None:
    from localemu.aws.api import CommonServiceException
    from localemu.services.iam_enforcement.enforcer import IAMEnforcementHandler
    from localemu.services.iam_enforcement.evaluator import Decision
    from localemu.services.iam_enforcement.identity import resolve_caller
    from localemu.services.iam_enforcement import enforcer as enforcer_mod

    original_call = IAMEnforcementHandler.__call__

    def _enforce_pass_role(self, context) -> None:
        _enforce, audit, enabled = self._read_mode()
        if not enabled or not context.service or not context.operation:
            return
        service_name = context.service.service_name
        passed_to = _PASSED_TO_SERVICE.get(service_name)
        if not passed_to:
            return
        access_key = enforcer_mod._extract_access_key(context)
        if self._is_internal_call(context, access_key) or not access_key:
            return
        account_id = context.account_id or "000000000000"
        caller = resolve_caller(access_key, account_id, context.region)
        if not caller or caller.principal_type == "Root":
            return
        params = context.service_request or {}
        found: list[str] = []
        _collect_passed_roles(params, found)
        profile_refs: list[str] = []
        _collect_instance_profile_refs(params, profile_refs)
        found.extend(_roles_from_instance_profiles(profile_refs, account_id))
        roles = list(dict.fromkeys(found))
        if not roles:
            return
        base = enforcer_mod._build_conditions(context, caller)
        for role_arn in roles:
            conditions = dict(base)
            conditions["iam:PassedToService"] = passed_to
            decision = self.evaluator.evaluate(
                caller=caller,
                action="iam:PassRole",
                resource=role_arn,
                conditions=conditions,
                resource_policy=None,
            )
            if decision == Decision.ALLOW:
                continue
            message = (
                f"User: {caller.arn} is not authorized to perform: "
                f"iam:PassRole on resource: {role_arn}"
            )
            if audit:
                LOG.warning("IAM AUDIT DENY: %s", message)
                return
            raise CommonServiceException(
                code="AccessDenied", message=message, status_code=403, sender_fault=True
            )

    def __call__(self, chain, context, response):
        original_call(self, chain, context, response)
        _enforce_pass_role(self, context)

    IAMEnforcementHandler.__call__ = __call__


_patch_sts()
_patch_pass_role()
LOG.info("awsbox oidc web-identity + PassRole patch applied")
