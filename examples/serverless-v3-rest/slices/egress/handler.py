"""VPC egress probe: public host, S3 via prefix-list IP, peer HTTP."""

from __future__ import annotations

import json
import urllib.error
import urllib.request

import boto3
from botocore.config import Config


def _fetch(url: str, timeout: float) -> dict:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            body = resp.read(200).decode("utf-8", errors="replace")
            return {"ok": 200 <= resp.status < 400, "detail": body}
    except Exception as exc:
        return {"ok": False, "detail": str(exc)}


def handler(event, _context):
    out: dict = {}
    timeout = float(event.get("timeoutMs") or 3000) / 1000.0
    if event.get("publicUrl"):
        out["public"] = _fetch(event["publicUrl"], timeout)
    if event.get("peerUrl"):
        out["peer"] = _fetch(event["peerUrl"], timeout)
    s3 = event.get("s3") or {}
    if s3:
        endpoint = s3.get("endpoint")
        bucket = s3.get("bucket")
        key = s3.get("key") or "egress.txt"
        region = s3.get("region") or "us-east-1"
        try:
            client = boto3.client(
                "s3",
                region_name=region,
                endpoint_url=endpoint,
                config=Config(s3={"addressing_style": "path"}),
            )
            client.put_object(Bucket=bucket, Key=key, Body=b"egress-ok")
            got = client.get_object(Bucket=bucket, Key=key)["Body"].read().decode()
            out["s3"] = {"ok": got == "egress-ok", "detail": got[:80]}
        except Exception as exc:
            out["s3"] = {"ok": False, "detail": str(exc)}
    return out


# Serverless Framework default looks for handler.handler; keep a CLI-friendly alias.
if __name__ == "__main__":
    print(json.dumps(handler(json.loads(input() or "{}"), None)))
