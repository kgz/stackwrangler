"""Omit empty ECS networkConfiguration (AWS omits; moto used {}).

Moto's Service.__init__ sets ``self.network_configuration = {}`` when the
caller did not pass awsvpc config. JSON serialization then emits
``"networkConfiguration": {}``. Real ECS omits the field for host/bridge
(non-awsvpc) services. The Terraform AWS provider panics when the key is
present without ``awsvpcConfiguration`` (#708).
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.ecs_omit_empty_networkconfig")


def _patch() -> None:
    from moto.ecs.models import Service

    if getattr(Service, "_awsbox_omit_empty_networkconfig", False):
        return

    original_init = Service.__init__

    def service_init(self, *args, **kwargs) -> None:
        original_init(self, *args, **kwargs)
        net = getattr(self, "network_configuration", None)
        if not net or not isinstance(net, dict) or "awsvpcConfiguration" not in net:
            self.network_configuration = None
            for dep in getattr(self, "deployments", []) or []:
                if isinstance(dep, dict) and not (
                    isinstance(dep.get("networkConfiguration"), dict)
                    and dep["networkConfiguration"].get("awsvpcConfiguration")
                ):
                    dep.pop("networkConfiguration", None)

    Service.__init__ = service_init
    Service._awsbox_omit_empty_networkconfig = True
    LOG.info("awsbox ECS omit empty networkConfiguration patch applied")


_patch()
