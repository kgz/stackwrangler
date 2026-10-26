---
name: release-version
description: >-
  Product release labels and git tags for awsbox. Use when creating tickets with
  a release label, cutting a semver release, tagging vX.Y.Z, or updating
  CURRENT_RELEASE / versioning docs.
---

# Release versioning

Milestones (`v1 — Networking`, …) are **service catalogues**. Product cuts are **labels + git tags** (`v0.0.1`, …).

Canonical docs: `docs/versioning.md`, `docs/CURRENT_RELEASE`.

## New tickets

```bash
REL=$(cat docs/CURRENT_RELEASE)
# after gh issue create … — add milestone as usual, then:
gh issue edit <n> --add-label "$REL"
```

Debt: same milestone area as parent + label `$REL` (or parent's release label if retargeting an older cut).

## Cut a release (only when the user asks)

```bash
./bin/release-tag.sh v0.0.2
```

Creates annotated tag on `origin/main` (or `--sha`), pushes tag, GitHub Release, ensures label exists, writes `docs/CURRENT_RELEASE`. Commit the CURRENT_RELEASE bump in a follow-up if the working tree should ship it.

Do **not** cut a release as a side effect of implementing a feature ticket.

## Bootstrap note

First product cut is **`v0.0.1`**. All existing issues at bootstrap carry label `v0.0.1`; catalogue milestone titles stay `v1 — …`.
