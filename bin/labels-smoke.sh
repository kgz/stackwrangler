#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/account/labels-smoke.sh" "$@"
