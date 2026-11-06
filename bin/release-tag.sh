#!/usr/bin/env bash
# Cut a product release: git tag + GitHub Release + label + CURRENT_RELEASE.
# Usage: ./bin/release-tag.sh <semver> [--no-push] [--sha <commit>]
# Example: ./bin/release-tag.sh v0.0.2
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ $# -lt 1 ]]; then
	echo "Usage: $0 <semver> [--no-push] [--sha <commit>]" >&2
	exit 1
fi

VER="$1"
shift
NO_PUSH=0
SHA=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--no-push) NO_PUSH=1; shift ;;
	--sha)
		SHA="${2:-}"
		[[ -n "$SHA" ]] || { echo "--sha needs a commit" >&2; exit 1; }
		shift 2
		;;
	*)
		echo "Unknown arg: $1" >&2
		exit 1
		;;
	esac
done

if [[ ! "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
	echo "Version must look like v0.0.1 (got: $VER)" >&2
	exit 1
fi

if [[ -z "$SHA" ]]; then
	git fetch origin main >/dev/null 2>&1 || true
	SHA="$(git rev-parse origin/main 2>/dev/null || git rev-parse main)"
fi

COLOR="0E8A16"
DESC="Product release bucket"

if ! gh api "repos/kgz/stackwrangler/labels/${VER}" >/dev/null 2>&1; then
	gh api repos/kgz/stackwrangler/labels -f name="$VER" -f color="$COLOR" -f description="$DESC" >/dev/null
	echo "created label $VER"
else
	echo "label $VER already exists"
fi

if git rev-parse "$VER" >/dev/null 2>&1; then
	echo "git tag $VER already exists locally"
else
	git tag -a "$VER" "$SHA" -m "stackwrangler $VER"
	echo "tagged $VER -> $SHA"
fi

if [[ "$NO_PUSH" -eq 0 ]]; then
	# Create the GitHub Release BEFORE pushing the tag so publish-images.yml can
	# upload install/stackwrangler (tag push alone races a missing release → 404).
	if ! gh release view "$VER" >/dev/null 2>&1; then
		gh release create "$VER" --target "$SHA" --title "stackwrangler $VER" \
			--notes "Product release $VER. See docs/versioning.md / docs/docker-install.md. Catalogue milestones remain \`v1 — …\`; track this cut via label \`$VER\`."
		echo "created GitHub release $VER"
	else
		echo "GitHub release $VER already exists"
	fi
	# Tag may already exist on the remote from `gh release create --target`.
	if git ls-remote --exit-code --tags origin "refs/tags/${VER}" >/dev/null 2>&1; then
		echo "tag $VER already on origin (from release create; ok)"
	else
		git push origin "refs/tags/$VER"
	fi
	# Ensure local tip matches remote even when release create minted the tag.
	git push origin "refs/tags/$VER" 2>/dev/null || true
else
	echo "skipped push/release (--no-push)"
fi

printf '%s\n' "$VER" >"$ROOT/docs/CURRENT_RELEASE"
echo "docs/CURRENT_RELEASE -> $VER"
echo "New tickets: pillar milestone + Impact/Effort; release label only if cut gate matches"
echo "GHCR images: tag push triggers .github/workflows/publish-images.yml (docs/docker-install.md)"
echo "CLI asset: workflow uploads install/stackwrangler onto release $VER (contents:write + ensure-release)"
