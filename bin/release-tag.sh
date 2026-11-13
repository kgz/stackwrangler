#!/usr/bin/env bash
# Cut a product release: git tag + GitHub Release + label + bump CURRENT_RELEASE to next.
# Usage: ./bin/release-tag.sh <semver> --next <next-semver> [--no-push] [--sha <commit>]
# Example: ./bin/release-tag.sh v0.0.6 --next v0.0.7
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
	echo "Usage: $0 <semver> --next <next-semver> [--no-push] [--sha <commit>]" >&2
	echo "  CURRENT_RELEASE is set to --next (the open cut), never the tag just shipped." >&2
}

if [[ $# -lt 1 ]]; then
	usage
	exit 1
fi

VER="$1"
shift
NO_PUSH=0
SHA=""
NEXT=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	--no-push) NO_PUSH=1; shift ;;
	--next)
		NEXT="${2:-}"
		[[ -n "$NEXT" ]] || { echo "--next needs a semver" >&2; exit 1; }
		shift 2
		;;
	--sha)
		SHA="${2:-}"
		[[ -n "$SHA" ]] || { echo "--sha needs a commit" >&2; exit 1; }
		shift 2
		;;
	*)
		echo "Unknown arg: $1" >&2
		usage
		exit 1
		;;
	esac
done

if [[ ! "$VER" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
	echo "Version must look like v0.0.1 (got: $VER)" >&2
	exit 1
fi

if [[ -z "$NEXT" ]]; then
	echo "error: --next <semver> is required so CURRENT_RELEASE advances past the shipped cut." >&2
	usage
	exit 1
fi

if [[ ! "$NEXT" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
	echo "--next must look like v0.0.7 (got: $NEXT)" >&2
	exit 1
fi

if [[ "$NEXT" == "$VER" ]]; then
	echo "error: --next must differ from the cut being shipped ($VER)" >&2
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

if ! gh api "repos/kgz/stackwrangler/labels/${NEXT}" >/dev/null 2>&1; then
	gh api repos/kgz/stackwrangler/labels -f name="$NEXT" -f color="$COLOR" -f description="$DESC" >/dev/null
	echo "created label $NEXT"
else
	echo "label $NEXT already exists"
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
	# `gh release create --target` may already have minted the tag on origin.
	if git push origin "refs/tags/$VER"; then
		echo "pushed tag $VER"
	elif git ls-remote --exit-code --tags origin "refs/tags/${VER}" >/dev/null 2>&1; then
		echo "tag $VER already on origin (ok)"
	else
		echo "error: failed to push tag $VER and it is missing on origin" >&2
		exit 1
	fi
else
	echo "skipped push/release (--no-push)"
fi

printf '%s\n' "$NEXT" >"$ROOT/docs/CURRENT_RELEASE"
echo "docs/CURRENT_RELEASE -> $NEXT (next open cut; shipped $VER)"
echo "Mark $VER shipped in docs/version-plan.md; open board view for $NEXT if needed."
echo "Strip leftover label:$VER from open issues (./bin/check-current-release.sh)."
echo "New tickets: pillar milestone + Impact/Effort; release label only if cut gate matches"
echo "GHCR images: tag push triggers .github/workflows/publish-images.yml (docs/docker-install.md)"
echo "CLI asset: workflow uploads install/stackwrangler onto release $VER (contents:write + ensure-release)"
