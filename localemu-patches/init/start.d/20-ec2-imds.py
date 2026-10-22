"""IMDS reachability when LocalEmu itself runs in Docker (#208).

The image binds IMDS to 127.0.0.1 and points the per-VPC sidecar at
host.docker.internal. On Linux that address is the bridge gateway, not
the emulator container, so IMDSv2 returns 502. EC2 containers also
cannot open the published gateway port when it is bound to 127.0.0.1
on the host. Point both the sidecar and AWS_ENDPOINT_URL at this
container's docker-network IP, and bind IMDS on 0.0.0.0.
"""

from __future__ import annotations

import logging

LOG = logging.getLogger("localemu.awsbox.ec2_imds")

_api_ip: str | None = None
_api_net: str | None = None


def _self_api() -> tuple[str | None, str | None]:
    global _api_ip, _api_net
    if _api_ip:
        return _api_ip, _api_net
    import os
    import socket

    from localemu.utils.docker_utils import DOCKER_CLIENT

    cid = os.environ.get("HOSTNAME") or socket.gethostname()
    try:
        info = DOCKER_CLIENT.inspect_container(cid)
    except Exception:
        LOG.warning("ec2-imds: cannot inspect self container %s", cid, exc_info=True)
        return None, None
    networks = (info.get("NetworkSettings") or {}).get("Networks") or {}
    for name, net in networks.items():
        if name.startswith("localemu-vpc-") or name.startswith("localemu-pubport"):
            continue
        ip = net.get("IPAddress") or ""
        if ip:
            _api_ip = ip
            _api_net = name
            LOG.info("ec2-imds: API reachable at %s on network %s", ip, name)
            return _api_ip, _api_net
    return None, None


def _patch_container_wiring() -> None:
    from localemu import config as le_config
    from localemu.services.ec2.docker import imds_sidecar as sidecar
    from localemu.utils.docker_utils import DOCKER_CLIENT

    port = le_config.GATEWAY_LISTEN[0].port
    orig_create = DOCKER_CLIENT.create_container_from_config
    orig_start = DOCKER_CLIENT.start_container
    orig_ensure = sidecar.ensure_imds_sidecar

    def create_container_from_config(cfg):
        name = cfg.name or ""
        ip, net = _self_api()
        if ip and name.startswith("localemu-imds-"):
            cfg.env_vars = dict(cfg.env_vars or {})
            cfg.env_vars["LOCALEMU_IMDS_UPSTREAM_HOST"] = ip
            if net:
                cfg.network = net
        elif ip and name.startswith("localemu-ec2-"):
            cfg.env_vars = dict(cfg.env_vars or {})
            cfg.env_vars["AWS_ENDPOINT_URL"] = f"http://{ip}:{port}"
        return orig_create(cfg)

    def start_container(container_name_or_id, *args, **kwargs):
        result = orig_start(container_name_or_id, *args, **kwargs)
        name = str(container_name_or_id)
        _ip, net = _self_api()
        if net and name.startswith("localemu-ec2-"):
            try:
                DOCKER_CLIENT.connect_container_to_network(net, name)
            except Exception:
                LOG.warning(
                    "ec2-imds: could not attach %s to %s", name, net, exc_info=True
                )
        return result

    def ensure_imds_sidecar(vpc_id: str, host_imds_port: int):
        ip, _net = _self_api()
        name = sidecar._sidecar_name(vpc_id)
        try:
            info = DOCKER_CLIENT.inspect_container(name)
            env = (info.get("Config") or {}).get("Env") or []
            want_host = f"LOCALEMU_IMDS_UPSTREAM_HOST={ip}"
            want_port = f"LOCALEMU_IMDS_UPSTREAM_PORT={host_imds_port}"
            if ip and (want_host not in env or want_port not in env):
                DOCKER_CLIENT.remove_container(name, force=True)
                sidecar._sidecar_ips.pop(vpc_id, None)
        except Exception:
            sidecar._sidecar_ips.pop(vpc_id, None)
        return orig_ensure(vpc_id, host_imds_port)

    DOCKER_CLIENT.create_container_from_config = create_container_from_config
    DOCKER_CLIENT.start_container = start_container
    sidecar.ensure_imds_sidecar = ensure_imds_sidecar


def _patch_imds_bind_and_routes() -> None:
    from http.server import HTTPServer

    from localemu.services.ec2.docker import imds as imds_mod

    class _BindAll(HTTPServer):
        def __init__(self, server_address, request_handler_class, bind_and_activate=True):
            host, listen_port = server_address
            if host == "127.0.0.1":
                host = "0.0.0.0"
            super().__init__((host, listen_port), request_handler_class, bind_and_activate)

    orig_start = imds_mod.ImdsServer.start

    def start(self):
        previous = imds_mod.HTTPServer
        imds_mod.HTTPServer = _BindAll
        try:
            return orig_start(self)
        finally:
            imds_mod.HTTPServer = previous

    imds_mod.ImdsServer.start = start

    orig_get = imds_mod.ImdsRequestHandler.do_GET
    orig_route = imds_mod.ImdsRequestHandler._route

    def _moto_instance(metadata: dict):
        import moto.backends as moto_backends

        account = metadata.get("account_id") or "000000000000"
        region = metadata.get("region") or "us-east-1"
        instance_id = metadata.get("instance_id") or ""
        if not instance_id:
            return None
        backend = moto_backends.get_backend("ec2")[account][region]
        return backend.get_instance_by_id(instance_id)

    def _tokens_required(metadata: dict) -> bool:
        try:
            inst = _moto_instance(metadata)
            opts = getattr(inst, "metadata_options", None)
            return bool(opts and getattr(opts, "http_tokens", "") == "required")
        except Exception:
            LOG.debug("ec2-imds: metadata options lookup failed", exc_info=True)
            return False

    def _instance_tags(metadata: dict) -> dict[str, str] | None:
        try:
            inst = _moto_instance(metadata)
            opts = getattr(inst, "metadata_options", None)
            if not opts or getattr(opts, "instance_metadata_tags", "") != "enabled":
                return None
            tags: dict[str, str] = {}
            for tag in inst.get_tags() or []:
                if not isinstance(tag, dict):
                    continue
                key = tag.get("Key", tag.get("key"))
                if not key:
                    continue
                value = tag.get("Value", tag.get("value", ""))
                tags[str(key)] = "" if value is None else str(value)
            return tags
        except Exception:
            LOG.debug("ec2-imds: tag lookup failed", exc_info=True)
            return None

    def _resolve_id(handler) -> str | None:
        server = handler.server
        stamped = handler.headers.get(imds_mod.STAMP_HEADER)
        if stamped and stamped in server.metadata_store:
            return stamped
        forwarded = handler.headers.get("X-Localemu-Source-Ip")
        if forwarded:
            found = server.resolve_instance(forwarded)
            if found:
                return found
        return server.resolve_instance(handler.client_address[0])

    def do_GET(self):
        instance_id = _resolve_id(self)
        if instance_id:
            metadata = self.server.metadata_store.get(instance_id) or {}
            if _tokens_required(metadata):
                token = self.headers.get("X-aws-ec2-metadata-token")
                if not token or not self.server.validate_token(token):
                    self.send_error(401, "Unauthorized - IMDSv2 token required")
                    return
        return orig_get(self)

    def _route(self, path: str, metadata: dict):
        listing = path in ("/latest/meta-data", "/latest/meta-data/")
        if listing:
            body = orig_route(self, path, metadata)
            tags = _instance_tags(metadata)
            if tags is not None and isinstance(body, str) and "tags/" not in body:
                return body + "\ntags/"
            return body
        if path in ("/latest/meta-data/tags", "/latest/meta-data/tags/"):
            if _instance_tags(metadata) is None:
                return None
            return "instance/"
        prefix = "/latest/meta-data/tags/instance"
        if path.rstrip("/") == prefix or path.startswith(prefix + "/"):
            tags = _instance_tags(metadata)
            if tags is None:
                return None
            if path.rstrip("/") == prefix:
                return "\n".join(sorted(tags))
            key = path[len(prefix) :].lstrip("/")
            if key not in tags:
                return None
            return tags[key]
        return orig_route(self, path, metadata)

    imds_mod.ImdsRequestHandler.do_GET = do_GET
    imds_mod.ImdsRequestHandler._route = _route


def _patch_send_command_arn() -> None:
    """SendCommand is authorized against the target instance, not an SSM parameter."""
    import localemu.services.iam_enforcement.arn_builder as arn_builder
    import localemu.services.iam_enforcement.enforcer as enforcer

    orig = arn_builder.build_resource_arn

    def build_resource_arn(service, operation, request_params, region, account_id):
        if service == "ssm" and operation == "SendCommand":
            params = request_params or {}
            ids = params.get("InstanceIds") or params.get("instanceIds") or []
            if isinstance(ids, str):
                ids = [ids]
            if isinstance(ids, list) and len(ids) == 1 and isinstance(ids[0], str) and ids[0]:
                return f"arn:aws:ec2:{region}:{account_id}:instance/{ids[0]}"
            doc = params.get("DocumentName") or params.get("documentName") or "*"
            if isinstance(doc, str) and doc.startswith("arn:"):
                return doc
            return f"arn:aws:ssm:{region}:{account_id}:document/{doc}"
        return orig(service, operation, request_params, region, account_id)

    arn_builder.build_resource_arn = build_resource_arn
    enforcer.build_resource_arn = build_resource_arn


_patch_container_wiring()
_patch_imds_bind_and_routes()
_patch_send_command_arn()
LOG.info("awsbox ec2 imds/ssm patches applied")
