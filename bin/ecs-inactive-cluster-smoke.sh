#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/compute/ecs-inactive-cluster-smoke.sh" "$@"
