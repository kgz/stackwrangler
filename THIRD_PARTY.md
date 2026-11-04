# Third-party notices

stackwrangler (MIT — see [LICENSE](LICENSE)) orchestrates open-source runtimes and libraries. This file lists the main ones shipped or invoked at runtime. It is **not** a complete transitive inventory of every npm/pip dependency.

**stackwrangler is not affiliated with Amazon Web Services, Inc.** Amazon, AWS, and related marks are trademarks of Amazon.com, Inc. or its affiliates. This project is an independent local development tool for AWS-shaped stacks, not an AWS product or a hosted substitute for AWS.

When you redistribute stackwrangler **together with** third-party bits (for example a vendored LocalEmu tree or their `NOTICE` file), keep that component’s license and NOTICE obligations.

---

## Runtime images (Docker Compose)

| Component | SPDX | Upstream | Role in stackwrangler |
|-----------|------|----------|------------------------|
| **LocalEmu** | Apache-2.0 | [localemu/localemu](https://github.com/localemu/localemu) · image `localemu/localemu` | Primary AWS API emulator (`:4566`) — IAM, Lambda, CFN, Transfer, RDS control plane, LocalEmu S3 for IaC/events, etc. |
| **moto** | Apache-2.0 | [getmoto/moto](https://github.com/getmoto/moto) | Used inside LocalEmu for many service backends (not a separate compose service here). |
| **SeaweedFS** | Apache-2.0 | [seaweedfs/seaweedfs](https://github.com/seaweedfs/seaweedfs) · image `chrislusf/seaweedfs` | Object store for console general-purpose buckets UI (`:8333`). |
| **distribution/registry** | Apache-2.0 | [distribution/distribution](https://github.com/distribution/distribution) · image `registry:2` | Local OCI registry used for ECR-shaped push/pull (`ecr-registry` service). |
| **atmoz/sftp** | MIT | [atmoz/sftp](https://github.com/atmoz/sftp) · image `atmoz/sftp` | SFTP sidecar used with Transfer Family local dataplane. |

Pinned digests / tags live in `docker-compose.yml` and `localemu-patches/IMAGE_DIGEST`.

---

## Vendored Python wheels (LocalEmu mounts)

| Component | SPDX | Upstream | Notes |
|-----------|------|----------|--------|
| **paramiko** (+ bcrypt, cryptography, PyNaCl, cffi, pycparser) | LGPL-2.1-or-later (paramiko) · Apache-2.0 / BSD-style deps | [paramiko/paramiko](https://github.com/paramiko/paramiko) | Wheels in `localemu-patches/wheels/` for Transfer SFTP client/server (#315). Unpacked at runtime into `/var/lib/awsbox/paramiko-site`. |

Pin / regenerate: `localemu-patches/wheels/README.md`.

---

## LocalEmu Apache NOTICE (redistribution)

LocalEmu is Apache-2.0 and ships a root **NOTICE** that preserves LocalStack / Atlassian lineage. **If you redistribute LocalEmu binaries, source, or a derivative that includes their NOTICE**, you must keep a readable copy of that attribution (Apache-2.0 §4(d)).

Upstream NOTICE (as published by LocalEmu; verify against the tag/digest you ship):

```text
LocalEmu
Copyright (c) 2026 TocConsulting and LocalEmu contributors

This product includes software developed by LocalStack Inc. and contributors
(Copyright (c) 2017-2026 LocalStack Inc and contributors), originally
released under the Apache License, Version 2.0. LocalEmu is a community
fork of the archived LocalStack community edition.

This product also includes portions originally developed by Atlassian Pty Ltd
(Copyright (c) 2016 Atlassian Pty Ltd), released under the Apache License,
Version 2.0, from which LocalStack itself was originally derived.

The full Apache License, Version 2.0 is reproduced in the LICENSE file at
the root of this repository, together with the preserved copyright lines
listed above.
```

Sources:

- <https://github.com/localemu/localemu/blob/main/NOTICE>
- <https://github.com/localemu/localemu/blob/main/LICENSE>
- <https://localemu.cloud/license/>

stackwrangler mounts patches under `localemu-patches/` into the LocalEmu container; those patches are part of this MIT-licensed tree. They do **not** remove LocalEmu’s Apache NOTICE obligations for the upstream image/code you pull from Docker Hub / GitHub.

---

## Console / Node dependencies (selected)

| Component | SPDX | Upstream | Notes |
|-----------|------|----------|--------|
| **AWS SDK for JavaScript v3** | Apache-2.0 | [aws/aws-sdk-js-v3](https://github.com/aws/aws-sdk-js-v3) | `@aws-sdk/client-*` packages in `console/package.json` |
| **React** | MIT | [facebook/react](https://github.com/facebook/react) | Console UI |
| **Vite** | MIT | [vitejs/vite](https://github.com/vitejs/vite) | Console build |
| **Monaco Editor** / `@monaco-editor/react` | MIT | [microsoft/monaco-editor](https://github.com/microsoft/monaco-editor) | Lambda code editor |
| **jszip** | MIT / GPL-3.0-or-later (dual) | [Stuk/jszip](https://github.com/Stuk/jszip) | Zip helpers in console |
| **yaml** | ISC | [eemeli/yaml](https://github.com/eemeli/yaml) | YAML parsing |
| **Playwright** (dev) | Apache-2.0 | [microsoft/playwright](https://github.com/microsoft/playwright) | Console e2e |

For a full lockfile inventory, see `console/package-lock.json`.

---

## Framing

Use stackwrangler to **test locally** (LocalEmu + sidecars) and **deploy to real AWS**. Depth and gaps are documented in the README and `docs/`; do not treat the local stack as a production AWS region or official AWS offering.
