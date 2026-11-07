"""CFN resource providers must not skip IAM via InternalClientFactory (#524).

``convert_payload`` built clients with ``InternalClientFactory``, which stamps
``x-localemu-data`` and makes every resource call an internal hop. Switch to an
external-style factory that still converts CFN property types, so deployer
credentials from the change-set executor are IAM-evaluated.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.cfn_caller_iam")


def _patch() -> None:
    from localemu import config
    from localemu.aws.connect import ExternalClientFactory
    from localemu.services.cloudformation import resource_provider as rp

    class ConvertingDeployClientFactory(ExternalClientFactory):
        def _get_client_post_hook(self, client):
            client.meta.events.register(
                "provide-client-params.*.*",
                handler=rp._handler_provide_client_params,
            )
            if config.IN_MEMORY_CLIENT:
                from localemu.aws.client import GatewayShortCircuit
                from localemu.runtime import get_current_runtime

                GatewayShortCircuit.modify_client(
                    client, get_current_runtime().components.gateway
                )
            return client

    rp._cfn_resource_client_factory = ConvertingDeployClientFactory(
        use_ssl=config.DISTRIBUTED_MODE
    )
    LOG.info("cfn caller-iam: resource provider client factory no longer internal")


_patch()
