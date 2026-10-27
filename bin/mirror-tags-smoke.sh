#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/account/mirror-tags-smoke.sh" "$@"
