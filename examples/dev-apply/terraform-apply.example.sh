#!/usr/bin/env bash
# Example post-`up` IaC hook (#290). Copy outside the repo (or under .awsbox/) —
# never commit real account names, state buckets, or credentials.
#
#   cp examples/dev-apply/terraform-apply.example.sh ~/.stackwrangler/dev-apply.sh
#   chmod +x ~/.stackwrangler/dev-apply.sh
#   export STACKWRANGLER_DEV_APPLY_HOOK=$HOME/.stackwrangler/dev-apply.sh
#   ./bin/stackwrangler up
#
# Keep the runner on an isolated Docker network with the emulator when you
# must not route to real AWS (docs/terraform-stackwrangler.md § Offline /
# isolated Docker network). Point provider + backend endpoints at LocalEmu.
set -euo pipefail

TF_ROOT="${STACKWRANGLER_DEV_APPLY_TF_ROOT:-$HOME/path/to/your-tf-stack}"
cd "$TF_ROOT"

# Idempotent: second up should plan empty when state and IaC agree.
terraform apply -input=false -auto-approve
