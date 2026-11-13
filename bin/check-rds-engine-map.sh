#!/usr/bin/env bash
# Compare pinned ENGINE_IMAGE_MAP against curated describe-db-engine-versions
# testdata. No AWS calls. Exit non-zero on gaps or floating tags.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAP="$ROOT/localemu-patches/rds_engine_mapping.py"
DATA="$ROOT/testdata/rds/describe-db-engine-versions.json"

[[ -f "$MAP" ]] || { echo "FAIL: missing $MAP" >&2; exit 1; }
[[ -f "$DATA" ]] || { echo "FAIL: missing $DATA" >&2; exit 1; }

python3 - "$MAP" "$DATA" <<'PY'
import importlib.util
import json
import re
import sys
from pathlib import Path

map_path = Path(sys.argv[1])
data_path = Path(sys.argv[2])

spec = importlib.util.spec_from_file_location("rds_engine_mapping", map_path)
if spec is None or spec.loader is None:
    sys.exit("cannot load engine map")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

FLOATING = re.compile(
    r"^(?:mysql|mariadb):(?:latest|5\.7|8\.0|8\.4)$|^(?:postgres):(?:latest|\d+)$"
)

errors: list[str] = []

for engine, versions in mod.ENGINE_IMAGE_MAP.items():
    for key, image in versions.items():
        if FLOATING.search(image) or mod._is_floating_tag(image):
            errors.append(f"floating tag {engine}/{key} -> {image}")

payload = json.loads(data_path.read_text())
for row in payload.get("DBEngineVersions") or []:
    engine = row["Engine"]
    version = row["EngineVersion"]
    try:
        image = mod.resolve_engine_image(engine, version)
    except mod.UnknownEngineVersionError as exc:
        errors.append(f"unmapped AWS version: {exc}")
        continue
    if mod._is_floating_tag(image):
        errors.append(f"AWS version {engine}/{version} resolved to floating {image}")

# Acceptance pins
checks = [
    ("mysql", "8.0.37", "mysql:8.0.37"),
    ("aurora-mysql", "8.0.mysql_aurora.3.05.2", "mysql:8.0.32"),
    ("aurora-mysql", "3.05.2", "mysql:8.0.32"),
]
for engine, version, want in checks:
    got = mod.resolve_engine_image(engine, version)
    if got != want:
        errors.append(f"pin {engine}/{version}: want {want}, got {got}")

try:
    mod.resolve_engine_image("mysql", "8.0.99")
    errors.append("mysql/8.0.99 should raise UnknownEngineVersionError")
except mod.UnknownEngineVersionError:
    pass

if errors:
    print("FAIL: RDS engine map check")
    for e in errors:
        print(f"  - {e}")
    sys.exit(1)

n = len(payload.get("DBEngineVersions") or [])
print(f"OK: engine map pinned; {n} AWS testdata versions resolve")
PY
