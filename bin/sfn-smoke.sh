#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/messaging/sfn-smoke.sh" "$@"
