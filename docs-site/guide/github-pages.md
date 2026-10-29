# Publishing (GitHub Pages)

This site is VitePress with `base: '/stackwrangler/'`, matching Runa’s pattern (`docs-site/` → `https://kgz.github.io/Runa/`).

## Local

```bash
cd docs-site
pnpm install
pnpm dev      # http://localhost:5173/stackwrangler/
pnpm build    # output: docs-site/.vitepress/dist
pnpm preview
```

## GitHub Pages URL

Intended public URL:

**https://kgz.github.io/stackwrangler/**

Source of truth for pages content: `docs-site/` on `main`.

## Deploy options

1. **GitHub Actions (preferred follow-up)** — on push to `main`, `pnpm build` in `docs-site/` and upload `.vitepress/dist` to the `github-pages` environment (or `peaceiris/actions-gh-pages`).
2. **Manual** — Settings → Pages → deploy from `gh-pages` branch or `/docs` after copying the build output (adjust `base` if the path changes).

Actions wiring is tracked as Debt [#425](https://github.com/kgz/stackwrangler/issues/425). The site must **build locally** either way.

## Assets

Console screenshots are shared under [`docs/assets/console/`](https://github.com/kgz/stackwrangler/tree/main/docs/assets/console). The VitePress `public/assets` path symlinks to that folder so README (#402) and this site use the same files.
