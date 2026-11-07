"""Record local-registry pushes in moto ECR and rewrite Lambda ECR image URIs (#211).

#219: image-based Lambda cold starts call ``ecr:BatchGetImage`` as the
function execution role before rewriting to the local registry. Shared
helpers live in ``awsbox_ecr_pull`` (also used by ECS task_manager).
"""

import json
import logging
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if "/opt/awsbox/ecr" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/ecr")
import awsbox_ecr_pull as ecr_pull  # noqa: E402

LOG = logging.getLogger("localemu.awsbox.ecr")

_HOOK_PORT = int(os.environ.get("AWSBOX_ECR_HOOK_PORT", "5099"))


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
        match = ecr_pull.ECR_IMAGE_RE.match(image)
        if not match:
            return image
        role_arn = getattr(getattr(self.function_version, "config", None), "role", None)
        vid = self.function_version.id
        region = getattr(vid, "region", None) or match.group("region")
        account_id = getattr(vid, "account", None) or match.group("account")
        fn_name = getattr(vid, "function_name", "lambda") or "lambda"
        resolved = ecr_pull.resolve_ecr_image(
            image,
            role_arn=role_arn,
            region=region,
            account_id=account_id,
            session_name=f"lambda-ecr-{fn_name}"[:64],
            role_label="function role",
        )
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
