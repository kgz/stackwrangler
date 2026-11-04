#!/usr/bin/env bash
# Add all open repo issues to GitHub Project #8 (Backlog) for stackwrangler.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

chmod +x bin/board-status.sh

issues=$(gh api "repos/kgz/stackwrangler/issues?state=open&per_page=100" --jq '.[].number')
if [[ -z "$issues" ]]; then
  echo "No open issues."
  exit 0
fi

# shellcheck disable=SC2086
./bin/board-status.sh backlog $issues

echo "Project: https://github.com/users/kgz/projects/8/views/1"
