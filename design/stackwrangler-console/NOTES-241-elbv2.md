# ELBv2 console screens — clone notes (Issue #241)

## Source of truth
Chrome (grey-rose palette, typography, layout, console JS) was copied from the stackwrangler console source (project `stackwrangler-console-545-wt`, `assets/console.css`, `assets/console.js`, `assets/fonts.css`) via the daemon file API — no guessing of tokens. Brand spec: charcoal chrome `#141414`/`#1c1c1c`, grey-rose accent `#b48aa0`, link rose `#e6d0da`, Source Sans 3 / Source Code Pro. No AWS orange, sky-blue, smile, Ember, or designer controls.

Reference patterns: `screens/ec2-vpcs.html` (list toolbar/table) and `screens/ecs-cluster-detail.html` (detail toolbar/kv) from the same source.

## Scope / mode
Read-only UI reproduction of two screens under `screens/`. No AWS API calls — no Load Balancer, listener, or target is created, updated, or deleted. Data is static sample content: network LB `elbv2-edge-demo`, TCP:443 listener forwarding to `elbv2-edge-targets`, two targets (healthy + unhealthy).

## Dead controls
Visible, `disabled` + `aria-disabled="true"` + `title="To implement"`: Refresh, Actions, Create load balancer, Create listener, plus chrome utilities and pager/select-all. No toast-only or enabled no-ops. Nothing "never ship" was included.

## Files
- `screens/ec2-load-balancers.html` + `.artifact.json`
- `screens/ec2-load-balancer-detail.html` + `.artifact.json`
- `assets/console.css`, `assets/console.js`, `assets/fonts.css`, `assets/README.md`

## Known gaps
- woff2 font binaries are not in this snapshot, so Source Sans 3 / Source Code Pro fall back to `Segoe UI` / `ui-monospace` where unavailable; CSS @font-face declarations remain verbatim.
- Services mega-panel is represented by a dead Services button rather than the full panel (outside the two-screen scope).
