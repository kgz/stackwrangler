#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/parity/aws-parity-cfn-authz.sh" "$@"
