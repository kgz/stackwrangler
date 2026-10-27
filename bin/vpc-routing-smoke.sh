#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/networking/vpc-routing-smoke.sh" "$@"
