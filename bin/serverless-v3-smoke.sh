#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/iac/serverless-v3-smoke.sh" "$@"
