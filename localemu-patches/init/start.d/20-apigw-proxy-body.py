"""Pass HTTP_PROXY request bodies through without form re-encoding (#364).

``rolo.request.restore_payload`` rebuilds ``application/x-www-form-urlencoded``
from Werkzeug's parsed ``request.form`` after the stream is consumed. A body
like ``{"a":"1"}`` (curl ``-d`` default Content-Type) becomes
``%7B%22a%22%3A%221%22%7D=``, so backends that expect the original bytes reject
it. AWS API Gateway HTTP_PROXY leaves the body untouched.

Cache the raw stream with ``get_data(parse_form_data=False)`` and return it.
Does not change ``20-apigw-vpc-link.py``.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.apigw_proxy_body")

_REBIND_MODULES = (
    "localemu.http.request",
    "localemu.services.apigateway.next_gen.execute_api.handlers.parse",
    "localemu.services.apigateway.legacy.router_asf",
    "localemu.services.lambda_.urlrouter",
    "localemu.aws.handlers.logging",
)


def _raw_restore_payload(request):
    if getattr(request, "shallow", False):
        return b""
    return request.get_data(cache=True, parse_form_data=False)


def _install() -> None:
    import rolo.request as rolo_request

    current = rolo_request.restore_payload
    if getattr(current, "_awsbox_proxy_body", False):
        return

    _raw_restore_payload._awsbox_proxy_body = True
    rolo_request.restore_payload = _raw_restore_payload

    for mod_path in _REBIND_MODULES:
        try:
            mod = __import__(mod_path, fromlist=["restore_payload"])
        except Exception:
            LOG.debug("awsbox proxy-body: skip import %s", mod_path, exc_info=True)
            continue
        if hasattr(mod, "restore_payload"):
            mod.restore_payload = _raw_restore_payload

    LOG.info("awsbox restore_payload raw body passthrough applied")


_install()
