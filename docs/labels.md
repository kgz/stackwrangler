# Console labels

Local display names for resource IDs and ARNs. The file stays **outside this repo** so account data is never committed. If `AWSBOX_LABELS` is unset or the file is missing, the console is unchanged and `GET /_awsl/labels` returns `{ "entries": [] }`.

```bash
# .env (see .env.example)
AWSBOX_LABELS=$HOME/awsbox-labels.yaml
```

`~/…` is expanded. A path inside the repo is gitignored if the file is named `labels.yaml`, but keep it outside anyway.

## Format

Top-level YAML mapping. Each key is an ID or ARN. `*` and `?` are globs (`*` matches across `:` and `/`). The value needs `label`. `note` and `link` are optional. `link` must be `http` or `https`. First matching key wins, so put specific patterns above broad ones.

```yaml
vpc-0123456789abcdef0:
  label: lab-vpc
  note: shared staging mirror
  link: https://example.internal/runbooks/lab-vpc

"arn:aws:elasticloadbalancing:*:*:loadbalancer/net/edge-*/*":
  label: edge-nlb
  note: internal network load balancer
  link: https://example.internal/edge-nlb
```

This emulator's network load balancer ARN uses `loadbalancer/app/` (moto). A glob such as `loadbalancer/*/` matches that and the AWS `loadbalancer/net/` form.

Restart is not required. The console dev server reads the file on each `GET /_awsl/labels`.

## Where it shows

Lists and detail pages show the label beside a matching ID or ARN (VPC list/detail, load balancer list/detail, and the other resource tables). The note is on the detail view. A link is the label text.

Load balancer rows come from `elbv2` (included in `docker-compose.yml` `SERVICES`). Recreate the localstack container after pulling that change.

```bash
./smokes/account/labels-smoke.sh
```
