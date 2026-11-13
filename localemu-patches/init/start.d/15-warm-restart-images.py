"""Warm restart prebuilts (#289): never install packages into workload nets.

- Probe-only ``ensure_iptables_in_container`` (no apk/apt/dnf/yum at task start).
  Callers without iptables use the alpine netns sidecar (``localemu/awsbox-rt``).
- Ensure ``localemu/ec2-base:v4`` and ``localemu/awsbox-rt:latest`` exist early
  so private VPC networks never need outbound package mirrors.
- Fail hard if required images cannot be ensured (do not boot without prebuilts).
"""

from __future__ import annotations

import logging
import sys

LOG = logging.getLogger("localemu.awsbox.warm_restart_images")


def _patch_ensure_iptables_probe_only() -> None:
    import localemu.services.ec2.docker.sg_iptables as sg_iptables

    if getattr(sg_iptables.ensure_iptables_in_container, "_awsbox_probe_only", False):
        return

    def ensure_iptables_in_container(container_name: str) -> bool:
        """Return True only when iptables is already runnable — never install."""
        if sg_iptables._probe_iptables(container_name, log_level=logging.DEBUG):
            return True
        LOG.error(
            "Container %s: iptables missing and runtime package install is "
            "disabled (#289). Use localemu/ec2-base (EC2) or the awsbox-rt "
            "netns sidecar (ECS/Lambda).",
            container_name,
        )
        return False

    ensure_iptables_in_container._awsbox_probe_only = True
    sg_iptables.ensure_iptables_in_container = ensure_iptables_in_container
    LOG.info("SG iptables: probe-only (no runtime apk/apt/dnf/yum) (#289)")


def _ensure_ec2_base() -> None:
    from localemu.services.ec2.docker.base_image import (
        BASE_IMAGE_TAG,
        ensure_base_image,
    )

    ensure_base_image()
    LOG.info("EC2 base image ready: %s", BASE_IMAGE_TAG)


def _ensure_rt_sidecar() -> None:
    from localemu.services.ec2.docker.vpc_routing import _ensure_rt_image

    tag = _ensure_rt_image()
    LOG.info("Route/SG sidecar image ready: %s", tag)


_patch_ensure_iptables_probe_only()
try:
    _ensure_ec2_base()
    _ensure_rt_sidecar()
except Exception:
    LOG.exception(
        "Warm-restart prebuilt images required (#289); refusing to continue "
        "without localemu/ec2-base:v4 and localemu/awsbox-rt:latest"
    )
    sys.exit(1)
