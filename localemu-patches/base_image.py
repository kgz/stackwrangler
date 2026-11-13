"""LocalEmu-managed EC2 base image — Dockerfile from /opt/awsbox/docker (#289).

Builds ``localemu/ec2-base:v4`` from the repo's ``docker/Dockerfile.ec2-base``
(single source of truth with ``bin/stackwrangler ensure_warm_images``).
"""

from __future__ import annotations

import logging
import os
import tempfile
import threading

from localemu.utils.docker_utils import DOCKER_CLIENT

LOG = logging.getLogger(__name__)

BASE_IMAGE_TAG = "localemu/ec2-base:v4"

_DOCKERFILE_PATHS = (
    os.environ.get("AWSBOX_EC2_BASE_DOCKERFILE", "").strip(),
    "/opt/awsbox/docker/Dockerfile.ec2-base",
)

_build_lock = threading.Lock()
_built_in_this_process: bool = False


def _dockerfile_path() -> str:
    for path in _DOCKERFILE_PATHS:
        if path and os.path.isfile(path):
            return path
    raise FileNotFoundError(
        "EC2 base Dockerfile missing (#289). Expected "
        "/opt/awsbox/docker/Dockerfile.ec2-base (compose mount or image COPY)."
    )


def _image_present() -> bool:
    try:
        DOCKER_CLIENT.inspect_image(BASE_IMAGE_TAG)
        return True
    except Exception:
        return False


def ensure_base_image(force_rebuild: bool = False) -> str:
    """Make sure ``localemu/ec2-base:v4`` exists; build it if not."""
    global _built_in_this_process

    if _built_in_this_process and not force_rebuild:
        return BASE_IMAGE_TAG

    with _build_lock:
        if _built_in_this_process and not force_rebuild:
            return BASE_IMAGE_TAG

        if not force_rebuild and _image_present():
            LOG.debug("Base image %s already present, skipping build", BASE_IMAGE_TAG)
            _built_in_this_process = True
            return BASE_IMAGE_TAG

        src = _dockerfile_path()
        LOG.info(
            "Building LocalEmu EC2 base image %s from %s (one-time)…",
            BASE_IMAGE_TAG,
            src,
        )
        with tempfile.TemporaryDirectory(prefix="localemu-ec2-base-") as ctx:
            dockerfile_path = os.path.join(ctx, "Dockerfile")
            with open(src, encoding="utf-8") as fh:
                body = fh.read()
            with open(dockerfile_path, "w", encoding="utf-8") as fh:
                fh.write(body)

            DOCKER_CLIENT.build_image(
                dockerfile_path=dockerfile_path,
                image_name=BASE_IMAGE_TAG,
                context_path=ctx,
            )

        LOG.info("Built %s successfully", BASE_IMAGE_TAG)
        _built_in_this_process = True
        return BASE_IMAGE_TAG
