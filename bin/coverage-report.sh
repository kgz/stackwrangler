#!/usr/bin/env bash
# Honest prove-coverage from smoke-matrix + test-paths + free-ci catalog.
# Usage:
#   ./bin/coverage-report.sh           # human summary
#   ./bin/coverage-report.sh --json    # machine
#   ./bin/coverage-report.sh --gaps    # list open gaps (matrix no/debt, paths thin/missing/debt)
#   ./bin/coverage-report.sh --self-test  # classifier + freeish unit checks
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=summary
for arg in "$@"; do
	case "$arg" in
	--json) MODE=json ;;
	--gaps) MODE=gaps ;;
	--self-test) MODE=self_test ;;
	-h | --help)
		sed -n '2,9p' "$0"
		exit 0
		;;
	*)
		echo "unknown arg: $arg" >&2
		exit 2
		;;
	esac
done

export COVERAGE_ROOT="$ROOT"
export COVERAGE_MODE="$MODE"
/usr/bin/python3 - <<'PY'
import json, os, re, sys
from pathlib import Path

root = Path(os.environ["COVERAGE_ROOT"])
mode = os.environ["COVERAGE_MODE"]

# --- smoke-matrix -----------------------------------------------------------
# Columns: Surface | Happy | Sad (authz) | Sad (other) | Console e2e | Script
NA = re.compile(r"^(?:—|-|–|n/?a|n\.a\.?)(?:\s|$)", re.I)
BOLD = re.compile(r"\*+")
# Status form: `no job run → [#335]` / `no … → #N` (ticket arrow), not prose arrows.
NO_TICKET_ARROW = re.compile(r"→\s*\[?#")

def classify_matrix_cell(raw: str) -> str:
    """Matrix cells: explicit no/debt/thin/missing = gap; — = n/a; else covered.

    Descriptive sad/console prose (e.g. 'up without docker.sock refused',
    'no default route; route removed', 'missing psql') documents what *is*
    tested — count as covered, not a gap. Leading-token `no`/`missing` alone
    is too greedy; only status forms count as gaps. `no <noun> → [#ticket]`
    is a deferred-status gap, not covered prose.
    """
    s = raw.strip()
    if not s or NA.match(s):
        return "na"
    plain = BOLD.sub("", s).strip()
    if not plain:
        return "na"
    first, _, rest = plain.partition(" ")
    word = first.lower()
    rest = rest.lstrip()
    if word == "yes":
        return "covered"
    if word == "no":
        # status: `no`, `no → …`, `no (…)`, `no <words> → [#N]` / `→ #N`
        if not rest or rest.startswith("→") or rest.startswith("("):
            return "gap"
        if NO_TICKET_ARROW.search(rest):
            return "gap"
        return "covered"
    if word in ("debt", "thin", "missing"):
        # status-only / ticket-linked; prose after missing/thin noun → covered
        if not rest:
            return "gap"
        if rest.startswith("[") or rest.startswith("#"):
            return "gap"
        if word == "debt":
            return "gap"
        if word == "thin":
            # `thin` / `thin list [#N]` are status, not sad-path prose
            return "gap"
        # missing <prose…> (e.g. missing psql, missing path / …)
        return "covered"
    # non-empty prose = covered claim (sad-path description, console depth, teardown)
    return "covered"


def freeish_cost_line(cost_line: str) -> bool:
    """Legacy aws-parity header cost line → count toward free-ci denominator."""
    low = cost_line.lower()
    metered = any(
        k in low
        for k in (
            "fargate",
            "alb",
            "nat",
            "rds",
            "eip",
            "≈ $",
            "~$0.0",
            "$0.0",
            "$0.02",
            "$0.05",
        )
    )
    return ("$0" in low or "free-tier" in low or "~$0" in low) and not metered


def run_self_test() -> int:
    """Unit checks for matrix classifier + freeish detection (#676)."""
    cases = [
        # covered prose (must not be greedy leading-token gaps)
        ("no default route; route removed", "covered"),
        ("no direct route without proxy env", "covered"),
        ("no direct route without proxy env; non-root image blocked", "covered"),
        ("no direct route without proxy; no default docker bridge (#271)", "covered"),
        ("missing psql", "covered"),
        ("missing path / non-zero apply exits non-zero", "covered"),
        ("missing file → no labels", "covered"),
        ("up without docker.sock refused", "covered"),
        ("list+detail", "covered"),
        ("teardown", "covered"),
        ("yes", "covered"),
        ("**yes**", "covered"),
        ("yes (alt ports via install)", "covered"),
        # explicit gaps
        ("no", "gap"),
        ("**no**", "gap"),
        ("no → [#310](https://example/310)", "gap"),
        ("no (parity gaps)", "gap"),
        ("no job run → [#335](https://example/335)", "gap"),
        ("no environment → [#335](https://example/335)", "gap"),
        ("no dataplane → #335", "gap"),
        ("debt [#742](https://example/742)", "gap"),
        ("thin", "gap"),
        ("thin list [#172](https://example/172)", "gap"),
        ("missing", "gap"),
        ("missing [#1](https://example/1)", "gap"),
        # n/a
        ("—", "na"),
        ("n/a", "na"),
        ("-", "na"),
    ]
    failed = 0
    for cell, want in cases:
        got = classify_matrix_cell(cell)
        if got != want:
            print(f"FAIL classify: {cell!r} -> {got!r} (want {want!r})", file=sys.stderr)
            failed += 1
    freeish_cases = [
        ("# cost: free-tier / $0", True),
        ("# cost: ~$0 local only", True),
        ("# cost: $0", True),
        ("# cost: ~$0.05 fargate", False),
        ("# cost: ≈ $0.02 alb", False),
        ("# cost: uses nat + eip", False),
        ("# no cost line keywords", False),
    ]
    for line, want in freeish_cases:
        got = freeish_cost_line(line)
        if got != want:
            print(f"FAIL freeish: {line!r} -> {got!r} (want {want!r})", file=sys.stderr)
            failed += 1
    if failed:
        print(f"coverage-report self-test: {failed} failure(s)", file=sys.stderr)
        return 1
    print(f"OK coverage-report self-test ({len(cases)} classify + {len(freeish_cases)} freeish)")
    return 0

matrix_gaps = []
matrix = {"covered": 0, "gap": 0, "na": 0, "cells": 0, "rows": 0}
matrix_path = root / "docs" / "smoke-matrix.md"
if matrix_path.is_file():
    in_table = False
    for lineno, line in enumerate(matrix_path.read_text(encoding="utf-8").splitlines(), 1):
        if line.startswith("| Surface |"):
            in_table = True
            continue
        if in_table and line.startswith("|---"):
            continue
        if in_table and not line.startswith("|"):
            in_table = False
            continue
        if not in_table or not line.startswith("|"):
            continue
        parts = [p.strip() for p in line.strip().strip("|").split("|")]
        if len(parts) < 5:
            continue
        surface = parts[0]
        if surface.lower() == "surface":
            continue
        matrix["rows"] += 1
        for col_i, col_name in enumerate(
            ("happy", "sad_authz", "sad_other", "console_e2e"), start=1
        ):
            if col_i >= len(parts):
                break
            cell = parts[col_i]
            kind = classify_matrix_cell(cell)
            matrix["cells"] += 1
            matrix[kind] = matrix.get(kind, 0) + 1
            if kind == "gap":
                matrix_gaps.append(
                    {
                        "file": "docs/smoke-matrix.md",
                        "line": lineno,
                        "surface": surface,
                        "column": col_name,
                        "cell": cell[:120],
                    }
                )

applicable_m = matrix["covered"] + matrix["gap"]
matrix_pct = (100.0 * matrix["covered"] / applicable_m) if applicable_m else 0.0

# --- test-paths -------------------------------------------------------------
paths = {"covered": 0, "thin": 0, "missing": 0, "debt": 0, "other": 0, "rows": 0}
path_gaps = []
paths_file = root / "docs" / "test-paths.md"
if paths_file.is_file():
    in_table = False
    for lineno, line in enumerate(paths_file.read_text(encoding="utf-8").splitlines(), 1):
        if line.startswith("| Path / scenario |"):
            in_table = True
            continue
        if in_table and line.startswith("|---"):
            continue
        if in_table and not line.startswith("|"):
            in_table = False
            continue
        if not in_table or not line.startswith("|"):
            continue
        parts = [p.strip() for p in line.strip().strip("|").split("|")]
        if len(parts) < 3:
            continue
        if parts[0].lower().startswith("path"):
            continue
        status = parts[2].lower()
        paths["rows"] += 1
        if status == "covered":
            paths["covered"] += 1
        elif status == "thin":
            paths["thin"] += 1
            path_gaps.append({"file": "docs/test-paths.md", "line": lineno, "path": parts[0], "status": status})
        elif status == "missing":
            paths["missing"] += 1
            path_gaps.append({"file": "docs/test-paths.md", "line": lineno, "path": parts[0], "status": status})
        elif status == "debt":
            paths["debt"] += 1
            path_gaps.append({"file": "docs/test-paths.md", "line": lineno, "path": parts[0], "status": status})
        else:
            paths["other"] += 1

applicable_p = paths["covered"] + paths["thin"] + paths["missing"] + paths["debt"]
# thin counts half toward covered for % (partial credit); missing/debt = 0
paths_score = paths["covered"] + 0.5 * paths["thin"]
paths_pct = (100.0 * paths_score / applicable_p) if applicable_p else 0.0

# --- free-ci catalog --------------------------------------------------------
catalog_path = root / "smokes" / "parity" / "catalog.yaml"
free_ci = []
free_tier = []
catalogued_scripts = set()
if catalog_path.is_file():
    text = catalog_path.read_text(encoding="utf-8")
    # lightweight block parse — enough for our catalog shape
    blocks = re.split(r"\n  - id:", text)
    for i, block in enumerate(blocks):
        if i == 0:
            continue
        bid_m = re.match(r"\s*([^\n]+)", block)
        if not bid_m:
            continue
        cid = bid_m.group(1).strip()
        suites_m = re.search(r"suites:\s*\[([^\]]*)\]", block)
        tier_m = re.search(r"cost_tier:\s*(\w+)", block)
        script_m = re.search(r"script:\s*(\S+)", block)
        suites = []
        if suites_m:
            suites = [s.strip().strip("'\"") for s in suites_m.group(1).split(",") if s.strip()]
        tier = tier_m.group(1) if tier_m else ""
        script = script_m.group(1) if script_m else ""
        if script:
            catalogued_scripts.add(Path(script).name)
        entry = {"id": cid, "suites": suites, "cost_tier": tier, "script": script}
        if "free-ci" in suites:
            free_ci.append(entry)
        if tier == "free":
            free_tier.append(entry)

legacy_dir = root / "smokes" / "parity"
uncatalogued_free = []
uncatalogued_other = []
if legacy_dir.is_dir():
    for p in sorted(legacy_dir.glob("aws-parity-*.sh")):
        if p.name in catalogued_scripts:
            continue
        head = p.read_text(encoding="utf-8", errors="replace")[:3000]
        rel = str(p.relative_to(root))
        cost_line = ""
        for line in head.splitlines():
            low = line.lower()
            if "cost" in low and ("$" in line or "free" in low):
                cost_line = low
                break
        if freeish_cost_line(cost_line):
            uncatalogued_free.append(rel)
        else:
            uncatalogued_other.append(rel)

# Denominator = free-tier in catalog + uncatalogued free legacy
free_denom = len({e["id"] for e in free_tier}) + len(uncatalogued_free)
free_num = len(free_ci)
free_pct = (100.0 * free_num / free_denom) if free_denom else 0.0

# overall: equal weight matrix + paths + free-ci inventory
overall = (matrix_pct + paths_pct + free_pct) / 3.0

report = {
    "overall_pct": round(overall, 1),
    "matrix": {
        "pct": round(matrix_pct, 1),
        "covered": matrix["covered"],
        "gap": matrix["gap"],
        "na": matrix["na"],
        "applicable": applicable_m,
        "rows": matrix["rows"],
    },
    "paths": {
        "pct": round(paths_pct, 1),
        "covered": paths["covered"],
        "thin": paths["thin"],
        "missing": paths["missing"],
        "debt": paths["debt"],
        "applicable": applicable_p,
        "rows": paths["rows"],
        "score": round(paths_score, 1),
    },
    "free_ci": {
        "pct": round(free_pct, 1),
        "in_suite": free_num,
        "free_tier_catalogued": len(free_tier),
        "uncatalogued_free": uncatalogued_free,
        "uncatalogued_other": uncatalogued_other,
        "denominator": free_denom,
        "ids": [e["id"] for e in free_ci],
    },
}

if mode == "self_test":
    sys.exit(run_self_test())

if mode == "json":
    print(json.dumps(report, indent=2))
    sys.exit(0)

if mode == "gaps":
    print(f"=== Coverage gaps (overall {report['overall_pct']}%) ===")
    print(f"\n-- smoke-matrix ({matrix['gap']} gap cells) --")
    for g in matrix_gaps[:80]:
        print(f"{g['file']}:{g['line']}: [{g['column']}] {g['surface']}: {g['cell']}")
    if len(matrix_gaps) > 80:
        print(f"... {len(matrix_gaps) - 80} more")
    print(f"\n-- test-paths ({paths['thin']+paths['missing']+paths['debt']} non-covered) --")
    for g in path_gaps[:80]:
        print(f"{g['file']}:{g['line']}: {g['status']}: {g['path']}")
    if len(path_gaps) > 80:
        print(f"... {len(path_gaps) - 80} more")
    print(f"\n-- free-ci uncatalogued free legacy --")
    for u in uncatalogued_free:
        print(u)
    if not uncatalogued_free:
        print("(none)")
    if uncatalogued_other:
        print(f"\n-- uncatalogued non-free (not in free-ci denom) --")
        for u in uncatalogued_other:
            print(u)
    sys.exit(0)

# summary
print("=== Prove coverage (honest inventory, not AWS %) ===")
print(f"Overall:     {report['overall_pct']}%  (mean of matrix / paths / free-ci)")
print(
    f"Matrix:      {report['matrix']['pct']}%  "
    f"({report['matrix']['covered']}/{report['matrix']['applicable']} applicable cells; "
    f"{report['matrix']['na']} n/a; {report['matrix']['rows']} rows)"
)
print(
    f"Test-paths:  {report['paths']['pct']}%  "
    f"(covered={paths['covered']} thin={paths['thin']} missing={paths['missing']} debt={paths['debt']}; "
    f"thin=0.5)"
)
print(
    f"Free-ci:     {report['free_ci']['pct']}%  "
    f"({free_num} in free-ci / {free_denom} free-tier+uncatalogued-free; "
    f"uncatalogued_free={len(uncatalogued_free)} other={len(uncatalogued_other)})"
)
print()
print("Raise % by: close matrix no/debt cells, cover thin/missing paths, catalogue free legacy into free-ci.")
print("Docs: docs/smoke-matrix.md · docs/test-paths.md · smokes/parity/catalog.yaml · docs/parity-suites.md")
PY
