"""Treat HostedZoneConfig.Comment as optional on CreateHostedZone (#681).

Moto 5.1.x does ``zone_config["Comment"]`` when HostedZoneConfig is present.
Real AWS and the CLI allow ``PrivateZone=true`` with no Comment; that KeyError
surfaces as InternalError. Inject an empty Comment into the request body before
the moto handler runs (including behind the custom-id wrapper).
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.r53_hostedzone_comment")


def _ensure_comment(response: object) -> None:
    body = getattr(response, "body", None)
    if not body:
        return
    try:
        import xmltodict

        parsed = xmltodict.parse(body)
    except Exception:
        LOG.debug("CreateHostedZone body parse failed", exc_info=True)
        return
    if not isinstance(parsed, dict):
        return
    zone = parsed.get("CreateHostedZoneRequest")
    if not isinstance(zone, dict):
        return
    cfg = zone.get("HostedZoneConfig")
    if not isinstance(cfg, dict) or "Comment" in cfg:
        return
    cfg["Comment"] = ""
    response.body = xmltodict.unparse(parsed)


def _patch() -> None:
    from moto.route53.responses import Route53

    original = Route53.create_hosted_zone

    def create_hosted_zone(self):
        _ensure_comment(self)
        return original(self)

    Route53.create_hosted_zone = create_hosted_zone
    LOG.info("awsbox route53 HostedZoneConfig.Comment optional")
    print("awsbox route53 HostedZoneConfig.Comment optional", flush=True)


_patch()
