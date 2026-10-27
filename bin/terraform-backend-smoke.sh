#!/usr/bin/env bash
exec "$(cd "$(dirname "$0")/.." && pwd)/smokes/iac/terraform-backend-smoke.sh" "$@"
