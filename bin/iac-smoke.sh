#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/iac/iac-smoke.sh" "$@"
