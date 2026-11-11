"""Record local-registry pushes in moto ECR and rewrite Lambda ECR image URIs (#211).

#219: image-based Lambda cold starts call ``ecr:BatchGetImage`` as the
function execution role before rewriting to the local registry. Shared
helpers live in ``awsbox_ecr_pull`` (also used by ECS task_manager).

#684: after LocalEmu restart with ``PERSISTENCE=0``, moto ECR is empty but
the registry volume still holds blobs. Re-push is a client no-op (manifest
exists), so the notify hook never fires. On start (and after
``create_repository``) walk ``/v2/_catalog`` + tags and re-record images.
"""

import json
import logging
import os
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

if "/opt/awsbox/ecr" not in sys.path:
    sys.path.insert(0, "/opt/awsbox/ecr")
import awsbox_ecr_pull as ecr_pull  # noqa: E402

LOG = logging.getLogger("localemu.awsbox.ecr")

_HOOK_PORT = int(os.environ.get("AWSBOX_ECR_HOOK_PORT", "5099"))
# Compose service DNS from inside LocalEmu (host 127.0.0.1:5000 is for the daemon).
_REGISTRY_URL = os.environ.get(
    "AWSBOX_ECR_REGISTRY_INTERNAL", "http://ecr-registry:5000"
).rstrip("/")
_MANIFEST_ACCEPT = (
    "application/vnd.oci.image.index.v1+json,"
    "application/vnd.oci.image.manifest.v1+json,"
    "application/vnd.docker.distribution.manifest.list.v2+json,"
    "application/vnd.docker.distribution.manifest.v2+json"
)
_RESYNC_LOCK = threading.Lock()
_ORIG_CREATE_REPOSITORY = None


def _backend_for_repository(name: str):
    from moto.ecr.models import ecr_backends

    for regions in ecr_backends.values():
        for backend in regions.values():
            if name in getattr(backend, "repositories", {}):
                return backend
    return None


def _default_backend():
    """Account/region used when catalog resync must create a missing repo."""
    from moto.ecr.models import ecr_backends

    account = (
        os.environ.get("AWSBOX_ACCOUNT_ID")
        or os.environ.get("STACKWRANGLER_ACCOUNT_ID")
        or "000000000000"
    ).strip() or "000000000000"
    region = (
        os.environ.get("AWS_DEFAULT_REGION")
        or os.environ.get("STACKWRANGLER_REGION")
        or os.environ.get("AWSBOX_REGION")
        or "us-east-1"
    ).strip() or "us-east-1"
    return ecr_backends[account][region]


def _ensure_repository(name: str):
    backend = _backend_for_repository(name)
    if backend is not None:
        return backend
    backend = _default_backend()
    create = _ORIG_CREATE_REPOSITORY or backend.create_repository
    try:
        create(
            backend,
            repository_name=name,
            registry_id=None,
            encryption_config={},
            image_scan_config=None,
            image_tag_mutability="MUTABLE",
            tags=[],
        )
        LOG.info("ecr catalog resync: created repository %s", name)
    except Exception as exc:
        if type(exc).__name__ != "RepositoryAlreadyExistsException":
            raise
    return backend


def _is_recordable_media(media: str) -> bool:
    """Docker/OCI manifests and OCI indexes (BuildKit provenance default)."""
    if not media:
        return False
    if "manifest" in media:
        return True
    # application/vnd.oci.image.index.v1+json — tag often points here, not a child manifest
    return "image.index" in media


def _put_recorded_image(
    *,
    repo: str,
    tag: str,
    media: str,
    digest: str | None,
    size: int = 0,
    source: str,
) -> None:
    backend = _backend_for_repository(str(repo))
    if backend is None:
        LOG.warning("ecr %s: no repository %s", source, repo)
        return
    manifest = json.dumps(
        {
            "schemaVersion": 2,
            "mediaType": media,
            "config": {
                "digest": digest,
                "size": size or 0,
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
            digest=digest,
        )
        LOG.info("ecr %s: %s:%s mediaType=%s", source, repo, tag, media)
    except Exception as exc:
        name = type(exc).__name__
        if name == "ImageAlreadyExistsException":
            LOG.info("ecr %s: %s:%s already recorded", source, repo, tag)
            return
        LOG.warning("ecr %s: put_image %s:%s failed: %s", source, repo, tag, exc)


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
        if not tag or not repo:
            continue
        if not _is_recordable_media(media):
            # Tagged blob/layer pushes are uncommon; warn so silent drops are visible (#683).
            LOG.warning(
                "ecr push hook: skip %s:%s unsupported mediaType=%s",
                repo,
                tag,
                media or "?",
            )
            continue
        _put_recorded_image(
            repo=str(repo),
            tag=str(tag),
            media=media,
            digest=target.get("digest"),
            size=int(target.get("size") or 0),
            source="push hook",
        )


def _registry_get(path: str, *, accept: str | None = None) -> tuple[bytes, dict]:
    headers = {}
    if accept:
        headers["Accept"] = accept
    req = urllib.request.Request(f"{_REGISTRY_URL}{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=5) as resp:
        body = resp.read()
        hdrs = {k.lower(): v for k, v in resp.headers.items()}
        return body, hdrs


def _resync_repository(repo: str, *, create_missing: bool = True) -> int:
    """Re-record tagged manifests for one registry repository into moto ECR."""
    recorded = 0
    try:
        raw, _ = _registry_get(f"/v2/{repo}/tags/list")
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return 0
        raise
    try:
        payload = json.loads(raw.decode() or "{}")
    except json.JSONDecodeError:
        LOG.warning("ecr catalog resync: bad tags list for %s", repo)
        return 0
    tags = payload.get("tags") if isinstance(payload, dict) else None
    if not isinstance(tags, list) or not tags:
        return 0
    if create_missing:
        _ensure_repository(repo)
    elif _backend_for_repository(repo) is None:
        return 0
    for tag in tags:
        if not isinstance(tag, str) or not tag:
            continue
        try:
            _body, hdrs = _registry_get(
                f"/v2/{repo}/manifests/{tag}",
                accept=_MANIFEST_ACCEPT,
            )
        except Exception as exc:
            LOG.warning(
                "ecr catalog resync: manifest %s:%s failed: %s", repo, tag, exc
            )
            continue
        media = str(hdrs.get("content-type") or "").split(";", 1)[0].strip()
        digest = hdrs.get("docker-content-digest")
        if not _is_recordable_media(media):
            LOG.warning(
                "ecr catalog resync: skip %s:%s unsupported mediaType=%s",
                repo,
                tag,
                media or "?",
            )
            continue
        if not digest:
            LOG.warning("ecr catalog resync: skip %s:%s missing digest", repo, tag)
            continue
        _put_recorded_image(
            repo=repo,
            tag=tag,
            media=media,
            digest=digest,
            size=len(_body),
            source="catalog resync",
        )
        recorded += 1
    return recorded


def _resync_catalog(*, create_missing: bool = True) -> int:
    """Walk registry catalog and re-record tags into moto ECR (#684)."""
    with _RESYNC_LOCK:
        raw, _ = _registry_get("/v2/_catalog")
        try:
            payload = json.loads(raw.decode() or "{}")
        except json.JSONDecodeError:
            LOG.warning("ecr catalog resync: bad /v2/_catalog")
            return 0
        repos = payload.get("repositories") if isinstance(payload, dict) else None
        if not isinstance(repos, list):
            return 0
        total = 0
        for repo in repos:
            if not isinstance(repo, str) or not repo:
                continue
            try:
                total += _resync_repository(repo, create_missing=create_missing)
            except Exception:
                LOG.exception("ecr catalog resync: repository %s failed", repo)
        return total


def _resync_loop() -> None:
    # ecr-registry depends_on localstack healthy, so registry is often late.
    for attempt in range(1, 61):
        try:
            n = _resync_catalog(create_missing=True)
            LOG.info("ecr catalog resync: recorded %s tag(s) (attempt %s)", n, attempt)
            return
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            if attempt == 1 or attempt % 10 == 0:
                LOG.info(
                    "ecr catalog resync: waiting for %s (%s)", _REGISTRY_URL, exc
                )
            time.sleep(2)
        except Exception:
            LOG.exception("ecr catalog resync failed")
            return
    LOG.warning("ecr catalog resync: gave up waiting for %s", _REGISTRY_URL)


def _patch_create_repository() -> None:
    """After create-repository, adopt tags still present in the registry (#684)."""
    global _ORIG_CREATE_REPOSITORY
    from moto.ecr.models import ECRBackend

    _ORIG_CREATE_REPOSITORY = ECRBackend.create_repository

    def create_repository(self, *args, **kwargs):
        repo = _ORIG_CREATE_REPOSITORY(self, *args, **kwargs)
        name = getattr(repo, "name", None) or kwargs.get("repository_name")
        if isinstance(name, str) and name:

            def _adopt() -> None:
                try:
                    with _RESYNC_LOCK:
                        n = _resync_repository(name, create_missing=False)
                    if n:
                        LOG.info(
                            "ecr catalog resync: adopted %s tag(s) for new repo %s",
                            n,
                            name,
                        )
                except Exception:
                    LOG.exception(
                        "ecr catalog resync after create_repository %s failed", name
                    )

            threading.Thread(
                target=_adopt,
                name=f"awsbox-ecr-adopt-{name}"[:40],
                daemon=True,
            ).start()
        return repo

    ECRBackend.create_repository = create_repository
    LOG.info("ecr create_repository adopts registry tags on create")


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
    _patch_create_repository()
except Exception:
    LOG.exception("ecr create_repository adopt not installed")
threading.Thread(target=_resync_loop, name="awsbox-ecr-resync", daemon=True).start()
try:
    _patch_lambda_images()
except Exception:
    LOG.exception("lambda ECR image rewrite not installed")
