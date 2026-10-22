#!/usr/bin/env python3
"""Mint a local OIDC JWT (sub/aud chosen by the caller) for awsbox tests.

Generates localemu-patches/oidc/test-key.pem + jwks.json on first use (gitignored).
LocalEmu verifies tokens against the mounted JWKS for issuer host awsbox.local.
"""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OIDC_DIR = ROOT / "localemu-patches" / "oidc"
KEY = OIDC_DIR / "test-key.pem"
JWKS = OIDC_DIR / "jwks.json"
KID = "awsbox-oidc-1"
DEFAULT_ISS = "https://awsbox.local/oidc"


def _b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def ensure_keypair() -> None:
    """Create RSA test key + matching JWKS if either file is missing."""
    OIDC_DIR.mkdir(parents=True, exist_ok=True)
    if KEY.is_file() and JWKS.is_file():
        return
    subprocess.check_call(
        ["openssl", "genrsa", "-out", str(KEY), "2048"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    KEY.chmod(0o600)
    mod_line = subprocess.check_output(
        ["openssl", "rsa", "-in", str(KEY), "-noout", "-modulus"],
        text=True,
    ).strip()
    if not mod_line.startswith("Modulus="):
        raise SystemExit(f"unexpected openssl modulus output: {mod_line!r}")
    n_b64 = _b64(bytes.fromhex(mod_line.split("=", 1)[1]))
    JWKS.write_text(
        json.dumps(
            {
                "keys": [
                    {
                        "kty": "RSA",
                        "kid": KID,
                        "use": "sig",
                        "alg": "RS256",
                        "n": n_b64,
                        "e": "AQAB",
                    }
                ]
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Mint an awsbox test OIDC JWT")
    parser.add_argument("--sub", required=False)
    parser.add_argument("--aud", default="sts.amazonaws.com")
    parser.add_argument("--iss", default=DEFAULT_ISS)
    parser.add_argument("--ttl", type=int, default=3600)
    parser.add_argument(
        "--ensure-only",
        action="store_true",
        help="Generate key+JWKS if missing, then exit",
    )
    args = parser.parse_args()
    ensure_keypair()
    if args.ensure_only:
        return
    if not args.sub:
        raise SystemExit("--sub is required unless --ensure-only")
    now = int(time.time())
    header = {"alg": "RS256", "typ": "JWT", "kid": KID}
    payload = {
        "iss": args.iss,
        "sub": args.sub,
        "aud": args.aud,
        "iat": now,
        "nbf": now,
        "exp": now + args.ttl,
    }
    signing_input = ".".join(
        (
            _b64(json.dumps(header, separators=(",", ":")).encode("utf-8")),
            _b64(json.dumps(payload, separators=(",", ":")).encode("utf-8")),
        )
    )
    signature = subprocess.check_output(
        ["openssl", "dgst", "-sha256", "-sign", str(KEY)],
        input=signing_input.encode("ascii"),
    )
    print(f"{signing_input}.{_b64(signature)}")


if __name__ == "__main__":
    main()
