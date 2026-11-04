# Vendored SFTP client wheels (#315)

Pinned for LocalEmu Python 3.13 / manylinux x86_64 (see `IMAGE_DIGEST`).

Regenerate inside the pinned image (no host pip):

```bash
digest=$(cut -d: -f2 localemu-patches/IMAGE_DIGEST)
docker run --rm \
  -v "$PWD/localemu-patches/wheels:/wheels" \
  --entrypoint bash \
  "localemu/localemu@sha256:${digest}" \
  -c 'pip download --dest /wheels -c /wheels/constraints.txt paramiko &&
      rm -f /wheels/*.metadata'
```

Mounted read-only at `/opt/awsbox/wheels`. Unpacked at runtime into
`/var/lib/awsbox/paramiko-site` (see `paramiko_vendor.py`).
