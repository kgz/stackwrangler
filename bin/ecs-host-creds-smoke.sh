#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/compute/ecs-host-creds-smoke.sh" "$@"
