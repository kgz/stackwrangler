# stackwrangler docs site

Maintainer notes for the VitePress site under `docs-site/`. Product guide pages live in `guide/` — do not put deploy/meta instructions there. Theme tokens follow `design/awsbox` (grey rose); do not invent a new palette.

**Intended public URL:** https://kgz.github.io/stackwrangler/

## Local

```bash
cd docs-site
pnpm install
pnpm dev      # http://127.0.0.1:5173/  (base `/`)
pnpm build    # docs-site/.vitepress/dist
pnpm preview  # http://127.0.0.1:4173/
```

On GitHub Pages / CI, `base` is `/stackwrangler/` (`GITHUB_PAGES=1` or `CI=true`). Locally that env is off so `pnpm dev` serves at `/`.

```bash
# Match Pages base locally (optional)
GITHUB_PAGES=1 pnpm build && GITHUB_PAGES=1 pnpm preview
# → http://127.0.0.1:4173/stackwrangler/
```

If the browser shows **workbox** / stale module errors on `:5173`, unregister service workers for that origin (DevTools → Application → Service Workers) and hard-refresh — VitePress does not ship Workbox.

## Vision sync

Public north star: [`guide/vision.md`](guide/vision.md). Repo source of truth: [`docs/vision.md`](../docs/vision.md). Keep them aligned; public page omits board/agent ops and uses **stackwrangler** naming throughout.

## GitHub Pages (prep now, live after public)

Workflow: [`.github/workflows/deploy-docs.yml`](../.github/workflows/deploy-docs.yml) (Runa-shaped).

1. Builds with pnpm in `docs-site/`
2. Uploads `docs-site/.vitepress/dist` as a Pages artifact
3. Deploys to the `github-pages` environment
4. Supports `workflow_dispatch` for dry-runs when Actions are allowed

**While the repo is private**, Pages deploys may no-op, fail, or be unavailable — that is expected. Do **not** block merges on a green Pages deploy. After the repo is public ([#413](https://github.com/kgz/stackwrangler/issues/413)):

1. Settings → Pages → Build and deployment → Source: **GitHub Actions**
2. Merge/push to `main` (or run **Deploy Documentation** via workflow_dispatch)
3. Site lands at https://kgz.github.io/stackwrangler/

Screenshots: [`docs/assets/console/`](../docs/assets/console/) via `public/assets` symlink (shared with README).
