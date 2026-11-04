# stackwrangler docs site

Maintainer notes for the VitePress site under `docs-site/`. Product guide pages live in `guide/` — do not put deploy/meta instructions there.

Public URL (when Pages is wired): https://kgz.github.io/stackwrangler/

```bash
pnpm install
pnpm dev      # http://127.0.0.1:5173/  (base `/`)
pnpm build    # docs-site/.vitepress/dist
pnpm preview
```

On GitHub Pages, `base` is `/stackwrangler/` (`GITHUB_PAGES=1` or `CI=true`). Locally that env is off so `pnpm dev` serves at `/`.

```bash
# Match Pages base locally (optional)
GITHUB_PAGES=1 pnpm build && GITHUB_PAGES=1 pnpm preview
# → http://127.0.0.1:4173/stackwrangler/
```

If the browser shows **workbox** / stale module errors on `:5173`, unregister service workers for that origin (DevTools → Application → Service Workers) and hard-refresh — VitePress does not ship Workbox.

## Deploy

1. **GitHub Actions (preferred)** — on push to `main`, `pnpm build` in `docs-site/` and upload `.vitepress/dist` (tracked as Debt [#425](https://github.com/kgz/stackwrangler/issues/425)).
2. **Manual** — Settings → Pages → `gh-pages` branch or copied build output.

Screenshots: [`docs/assets/console/`](../docs/assets/console/) via `public/assets` symlink (shared with README).
