"""Route REST custom-domain Hosts before the edge falls through to S3.

A longer base path wins. ``(none)`` is the root mapping. No match is 403 Forbidden.
The request is rewritten onto ``/restapis/<id>/<stage>/_user_request_``, which both
the legacy and next_gen routers already serve.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.apigw_custom_domain")

_PASSTHROUGH = object()
_REWRITTEN = object()


def _hostname(request) -> str:
    raw = (request.environ.get("HTTP_HOST") or "").split(",")[0].strip().lower()
    if raw.startswith("["):
        return raw
    host, sep, port = raw.rpartition(":")
    if sep and port.isdigit():
        raw = host
    return raw.rstrip(".")


def _skip_host(host: str) -> bool:
    if not host or host == "localhost":
        return True
    parts = host.split(".")
    if len(parts) == 4 and all(part.isdigit() and 0 <= int(part) <= 255 for part in parts):
        return True
    return False


def _find_store(host: str):
    from localemu.services.apigateway.models import apigateway_stores

    for _account, _region, store in apigateway_stores.iter_stores():
        names = store.domain_names
        if not names:
            continue
        if host in names:
            return store, host
        for name in names:
            if name.lower().rstrip(".") == host:
                return store, name
    return None, None


def _select_mapping(mappings: list, path: str):
    if not path.startswith("/"):
        path = "/" + path
    comparable = path if path == "/" else path.rstrip("/")
    best = None
    best_len = -1
    for mapping in mappings:
        base = str(mapping.get("basePath") or "(none)").strip()
        if base in ("(none)", "", "/"):
            length = 0
            remainder = path
        else:
            prefix = "/" + base.strip("/")
            if comparable != prefix and not comparable.startswith(prefix + "/"):
                continue
            length = len(prefix)
            remainder = path[length:] or "/"
            if not remainder.startswith("/"):
                remainder = "/" + remainder
        if length > best_len:
            best = (mapping, remainder)
            best_len = length
    return best


def _forbidden():
    from localemu.http import Response

    response = Response(status=403)
    response.set_json({"message": "Forbidden"})
    return response


def _rewrite(request, api_id: str, stage: str, remainder: str) -> None:
    suffix = "" if remainder in ("", "/") else remainder
    path = f"/restapis/{api_id}/{stage}/_user_request_{suffix}"
    query = request.query_string.decode() if request.query_string else ""
    raw = f"{path}?{query}" if query else path
    request.environ["PATH_INFO"] = path
    request.environ["RAW_URI"] = raw
    request.environ["REQUEST_URI"] = raw
    request.__dict__.pop("path", None)


def _prepare(request):
    host = _hostname(request)
    if _skip_host(host):
        return _PASSTHROUGH
    store, domain = _find_store(host)
    if store is None:
        return _PASSTHROUGH
    from rolo.request import get_raw_path

    mappings = store.base_path_mappings.get(domain) or []
    selected = _select_mapping(mappings, get_raw_path(request) or "/")
    if selected is None:
        return _forbidden()
    mapping, remainder = selected
    api_id = mapping.get("restApiId")
    stage = mapping.get("stage")
    if not api_id or not stage:
        return _forbidden()
    _rewrite(request, api_id, stage, remainder)
    return _REWRITTEN


def _install() -> None:
    from localemu.aws.handlers.legacy import EdgeRouterHandler

    if getattr(EdgeRouterHandler, "_awsbox_custom_domain", False):
        return

    original = EdgeRouterHandler.__call__

    def __call__(self, chain, context, response):
        prepared = _prepare(context.request)
        if prepared is _PASSTHROUGH:
            return original(self, chain, context, response)
        if prepared is not _REWRITTEN:
            response.update_from(prepared)
            chain.stop()
            return None
        return original(self, chain, context, response)

    EdgeRouterHandler.__call__ = __call__
    EdgeRouterHandler._awsbox_custom_domain = True
    LOG.info("awsbox REST custom domain routing applied")


_install()
