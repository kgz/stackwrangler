#!/usr/bin/env bash
# Retired name (#162): dual-split assertion replaced by single org-path brain.
# Kept as a shim so older docs / e2e lists keep working.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$ROOT/smokes/s3/s3-org-path-brain-smoke.sh"
