#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/networking/r53-private-smoke.sh" "$@"
