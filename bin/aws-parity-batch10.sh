#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/parity/aws-parity-batch10.sh" "$@"
