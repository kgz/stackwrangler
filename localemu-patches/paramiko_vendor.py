"""Load paramiko from wheels shipped under /opt/awsbox/wheels (#315).

No PyPI / outbound network. Wheels are unpacked once into
/var/lib/awsbox/paramiko-site (compose mounts .awsbox there).
"""

from __future__ import annotations

import sys
import threading
import zipfile
from pathlib import Path

_LOCK = threading.Lock()
_WHEELS = Path("/opt/awsbox/wheels")
_SITE = Path("/var/lib/awsbox/paramiko-site")
_MARKER = _SITE / ".awsbox-paramiko-ready"


def _unpack() -> None:
    if _MARKER.is_file() and (_SITE / "paramiko").is_dir():
        return
    wheels = sorted(_WHEELS.glob("*.whl"))
    if not wheels:
        raise RuntimeError(
            f"no paramiko wheels under {_WHEELS} — see localemu-patches/wheels/README.md"
        )
    _SITE.mkdir(parents=True, exist_ok=True)
    for whl in wheels:
        with zipfile.ZipFile(whl) as zf:
            zf.extractall(_SITE)
    _MARKER.write_text("ok\n", encoding="utf-8")


def ensure_paramiko():
    try:
        import paramiko

        return paramiko
    except ImportError:
        pass
    with _LOCK:
        try:
            import paramiko

            return paramiko
        except ImportError:
            pass
        _unpack()
        site = str(_SITE)
        if site not in sys.path:
            sys.path.insert(0, site)
        import paramiko

        return paramiko
