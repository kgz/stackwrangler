#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/compute/ec2-smoke.sh" "$@"
