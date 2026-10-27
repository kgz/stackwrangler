#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/networking/vpc-egress-smoke.sh" "$@"
