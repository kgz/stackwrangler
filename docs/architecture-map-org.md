# Architecture map — one-account platform topology (#389)

**Purpose:** fill a **single** awsbox / LocalEmu account with a realistic multi-tier control-plane shape so the honesty map has something true to draw — not 1000 AWS “tenants.”

## The shape (what we mean by “org scale”)

One AWS-shaped account. Traffic and apps look like a hosting / SaaS platform:

```
Internet
  → NLB / ALB
  → EC2 edge (Traefik / nginx; Puppet-managed)     public / DMZ
  → Lambda (webhooks / glue)
  → S3 (static, uploads, artefacts)
  → ECS microservices (several services, talk to each other)
  → several RDS (app, analytics, maybe shared)
  + SQS / roles / routes / TGs that prove the edges
```

“Lots of clients” is a **product** concern (app multi-tenancy inside those services). It is **not** “spin up thousands of tagged AWS resource trees.” The map’s job is still honesty: extra IAM Allows, orphan queues, missing SG proof — on this platform graph.

## Seeds

| Script | Role |
|--------|------|
| `./bin/architecture-map-seed.sh` | **Primary / live-shaped** — VPC, IGW, NLB+ALB, EC2 edge, Lambdas, S3, ECS mesh, SQS, several RDS, surprise IAM Allows |
| `./bin/architecture-map-classic-seed.sh` | **Classic HA diagram** — Users → R53 → ALB → ASG web (2 AZ) → ALB → ASG app → RDS Multi-AZ + S3 static. CloudFront not in LocalEmu `SERVICES` (honest gap; R53 aliases the web ALB). Classic ELB disabled → elbv2 ALBs |
| `./bin/architecture-map-org-seed.sh` | **UI stress only** — CRM `t000N` sprawl in one account. Not a realistic live topology; keep it to thrash the map (filter, pan/zoom, Allow fan-out). Not the product north star |

```bash
# realistic platform (preferred)
./bin/architecture-map-seed.sh

# optional NAT (can rattle a busy LocalEmu)
AWSBOX_ARCH_MAP_NAT=1 ./bin/architecture-map-seed.sh

# classic three-tier HA slide (VPC 10.0.0.0/16, Name=classic-3tier-*)
./bin/architecture-map-classic-seed.sh
```

## Classic three-tier (diagram seed)

Mirrors the public AWS HA slide (Users → R53 → CDN → S3 / VPC ELB → ASG web → ELB → ASG app → RDS Multi-AZ):

| Diagram | LocalEmu seed |
|---------|----------------|
| Route 53 | Public zone `classic-3tier.awsbox.test` — `www` → web ALB, `static` → S3 |
| CloudFront | **Gap** — not in `SERVICES`; do not invent a CDN node |
| Classic ELB | **elbv2 ALBs** (classic `elb` not enabled) |
| ASG web / app | 2 instances each across AZs; TG registration explicit (LocalEmu) |
| RDS Multi-AZ | `classic-3tier-db` with `--multi-az` |

Map kinds added for this shape: `route53`, `asg`, plus ALB→EC2 via `DescribeTargetHealth`.

## Honesty scenarios (still the point)

1. **Intended:** NLB/ALB → edge → services → one DB / queue.  
2. **Surprise:** task/role Allow that reaches more S3/RDS/SQS than the happy-path slide.  
3. **Orphans / gaps:** DLQ with no consumer; SG peer / resource policies still listed as gaps until mapped; CloudFront on the classic diagram.

## Map UX

- All proven joins drawn; select a node to highlight its flow.  
- Pan / zoom the canvas.  
- Tenant filter remains for leftovers from the old CRM seed — ignore for the platform seed.

## Non-goals

- Literally N AWS accounts or 10k IAM users per “client.”  
- Pretending Puppet/Traefik run inside LocalEmu EC2 — instances are **tagged control-plane stand-ins** the map can place; runtime is whatever the emulator supports.
