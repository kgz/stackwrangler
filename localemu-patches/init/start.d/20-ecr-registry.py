"""Record local-registry pushes in moto ECR and rewrite Lambda ECR image URIs (#211).

#219: image-based Lambda cold starts call ``ecr:BatchGetImage`` as the
function execution role before rewriting to the local registry.
"""

import json
import logging
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = logging.getLogger("localemu.awsbox.ecr")

_ECR_IMAGE_RE = re.compile(
    r"^(?P<account>\d+)\.dkr\.ecr\.(?P<region>[a-z0-9-]+)\.amazonaws\.com/(?P<ref>.+)$"
)
_HOOK_PORT = int(os.environ.get("AWSBOX_ECR_HOOK_PORT", "5099"))


def _local_ref(image: str) -> str:
    match = _ECR_IMAGE_RE.match(image)
    if not match:
        return image
    registry = os.environ.get("AWSBOX_ECR_REGISTRY", "127.0.0.1:5000").strip().rstrip("/")
    return f"{registry}/{match.group('ref')}"


def _ecr_image_id(ref: str) -> tuple[str, dict]:
    if "@" in ref:
        name, digest = ref.split("@", 1)
        return name, {"imageDigest": digest}
    if ":" in ref:
        name, tag = ref.rsplit(":", 1)
        return name, {"imageTag": tag}
    return ref, {"imageTag": "latest"}


def _is_access_denied(exc: BaseException) -> bool:
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


def _role_boto_kwargs(*, role_arn: str, region: str, account_id: str, session_name: str) -> dict:
    """Boto3 kwargs signed as the function role via the gateway (IAM enforced)."""
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


def _authorize_lambda_ecr_pull(image: str, function_version) -> None:
    """Require function role ``ecr:BatchGetImage`` before a local-registry pull."""
    match = _ECR_IMAGE_RE.match(image)
    if not match:
        return

    role_arn = getattr(getattr(function_version, "config", None), "role", None)
    if not role_arn:
        raise RuntimeError(
            "CannotPullContainerError: function role is not specified "
            "for ECR image pull (ecr:BatchGetImage)"
        )

    import boto3

    vid = function_version.id
    region = getattr(vid, "region", None) or match.group("region")
    account_id = getattr(vid, "account", None) or match.group("account")
    ref = match.group("ref")
    repository, image_id = _ecr_image_id(ref)
    fn_name = getattr(vid, "function_name", "lambda") or "lambda"
    ecr = boto3.client(
        "ecr",
        **_role_boto_kwargs(
            role_arn=role_arn,
            region=region,
            account_id=account_id,
            session_name=f"lambda-ecr-{fn_name}"[:64],
        ),
    )
    try:
        resp = ecr.batch_get_image(
            repositoryName=repository,
            imageIds=[image_id],
        )
    except Exception as e:
        if _is_access_denied(e):
            raise RuntimeError(
                "CannotPullContainerError: function role is not "
                "authorized to perform ecr:BatchGetImage"
            ) from e
        raise RuntimeError(f"CannotPullContainerError: {e}") from e
    for failure in resp.get("failures") or []:
        code = str(failure.get("failureCode") or "")
        if "accessdenied" in code.lower().replace("_", ""):
            raise RuntimeError(
                "CannotPullContainerError: function role is not "
                "authorized to perform ecr:BatchGetImage"
            )


def _backend_for_repository(name: str):
    from moto.ecr.models import ecr_backends

    for regions in ecr_backends.values():
        for backend in regions.values():
            if name in getattr(backend, "repositories", {}):
                return backend
    return None


def _record_push(payload: bytes) -> None:
    try:
        body = json.loads(payload.decode() or "{}")
    except json.JSONDecodeError:
        LOG.warning("ecr push hook: invalid JSON")
        return
    events = body.get("events") if isinstance(body, dict) else None
    if not isinstance(events, list):
        return
    for event in events:
        if not isinstance(event, dict) or event.get("action") != "push":
            continue
        target = event.get("target") or {}
        if not isinstance(target, dict):
            continue
        media = str(target.get("mediaType") or "")
        tag = target.get("tag")
        repo = target.get("repository")
        if not tag or not repo or "manifest" not in media:
            continue
        backend = _backend_for_repository(str(repo))
        if backend is None:
            LOG.warning("ecr push hook: no repository %s", repo)
            continue
        manifest = json.dumps(
            {
                "schemaVersion": 2,
                "mediaType": media,
                "config": {
                    "digest": target.get("digest"),
                    "size": target.get("size") or 0,
                },
                "layers": [],
            }
        )
        try:
            backend.put_image(
                repository_name=str(repo),
                image_manifest=manifest,
                image_tag=str(tag),
                image_manifest_mediatype=media,
                digest=target.get("digest"),
            )
            LOG.info("ecr push hook: %s:%s", repo, tag)
        except Exception as exc:
            name = type(exc).__name__
            if name == "ImageAlreadyExistsException":
                LOG.info("ecr push hook: %s:%s already recorded", repo, tag)
                continue
            LOG.warning("ecr push hook: put_image %s:%s failed: %s", repo, tag, exc)


class _Handler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        payload = self.rfile.read(length) if length else b""
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")
        try:
            _record_push(payload)
        except Exception:
            LOG.exception("ecr push hook failed")

    def log_message(self, fmt: str, *args) -> None:
        LOG.debug("ecr push hook " + fmt, *args)


def _serve() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", _HOOK_PORT), _Handler)
    LOG.info("ecr push hook listening on %s", _HOOK_PORT)
    server.serve_forever()


def _patch_lambda_images() -> None:
    from localemu.services.lambda_.invocation.docker_runtime_executor import (
        DockerRuntimeExecutor,
    )
    from localemu.utils.docker_utils import DOCKER_CLIENT

    original = DockerRuntimeExecutor.get_image

    def get_image(self):
        image = original(self)
        resolved = _local_ref(image)
        if resolved == image:
            return image
        _authorize_lambda_ecr_pull(image, self.function_version)
        try:
            DOCKER_CLIENT.pull_image(resolved)
        except Exception:
            LOG.warning("lambda ECR pull %s failed", resolved, exc_info=True)
        return resolved

    DockerRuntimeExecutor.get_image = get_image
    LOG.info(
        "lambda ECR image URIs rewrite to %s (BatchGetImage via function role)",
        os.environ.get("AWSBOX_ECR_REGISTRY", "127.0.0.1:5000"),
    )


threading.Thread(target=_serve, name="awsbox-ecr-hook", daemon=True).start()
try:
    _patch_lambda_images()
except Exception:
    LOG.exception("lambda ECR image rewrite not installed")
