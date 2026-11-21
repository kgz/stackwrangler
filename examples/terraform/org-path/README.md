# Terraform: org-path stack (Transfer → Lambda → S3 → ECS → RDS)

One applyable stack for the [v0.1.0 org learning path](https://github.com/kgz/stackwrangler/issues/91):

**VPC → Transfer Family (SFTP) → Lambda → S3 → ECS task → RDS**

All APIs (including S3) target LocalEmu `STACKWRANGLER_IAM_ENDPOINT` → **`http://127.0.0.1:4566`**. Do **not** point this example at SeaweedFS `:8333`.

Depends on [#162](https://github.com/kgz/stackwrangler/issues/162) so `aws --profile local s3` and the console buckets UI share that same LocalEmu store. Until #162 is merged, IaC/`--endpoint-url :4566` still creates the path bucket, but profile `local` / console may still show SeaweedFS only — see [s3-backends.md](../../../docs/s3-backends.md).

E2E data-plane smoke is sibling [#781](https://github.com/kgz/stackwrangler/issues/781). Broader real-vs-stub docs: [#782](https://github.com/kgz/stackwrangler/issues/782).

## Prerequisites

```bash
# from repo root
./bin/stackwrangler up
# Terraform ≥ 1.5 + AWS provider 5.x
```

Console: <http://127.0.0.1:3000> · APIs: `:4566` · SFTP host port: `${STACKWRANGLER_SFTP_HOST_PORT:-2222}` · profile `local`.

Product admin keys (IAM enforced): `stackwrangler` / `stackwranglerstackwrangler`.

## Apply

```bash
cd examples/terraform/org-path
terraform init
terraform apply -auto-approve

# skip Docker Postgres if CreateDBInstance stalls (#718):
# terraform apply -auto-approve -var=create_rds=false
```

Writes an ed25519 private key to `build/sftp_id_ed25519` (gitignored).

## What it creates

| Hop | Resource | Notes |
|-----|----------|-------|
| VPC | `aws_vpc` + subnet + ECS SG | Unique CIDR default `10.91.0.0/16` |
| Transfer | SFTP server + SERVICE_MANAGED user + SSH key | Home = `/${bucket}`; native SFTP on host port |
| S3 | inbox bucket on **:4566** | ObjectCreated → Lambda for `inbox/` |
| Lambda | `nodejs18.x` marker writer | Writes `markers/org-path.txt` |
| ECS | Fargate-style task def + cluster | Env: `BUCKET_NAME`, `MARKER_KEY`, `RDS_ENDPOINT`; does **not** auto-run |
| RDS | Postgres 15 (optional) | LocalEmu Docker engine; `skip_final_snapshot` |

## Verify (CLI + console)

```bash
terraform output -raw verify_cli | bash
terraform output console_deep_links
```

Deep-links (where UIs exist):

| Surface | Path |
|---------|------|
| VPC | `/ec2/vpcs/<vpc-id>` |
| Transfer servers | `/transfer` |
| Lambda | `/lambda` |
| S3 buckets | `/` (General purpose) — after #162 lists LocalEmu |
| ECS | `/ecs/clusters/<name>` |
| RDS | `/rds` |

`list-servers` / `list-users` on Transfer may be empty on LocalEmu — use `describe-server` / `describe-user` ([transfer.md](../../../docs/transfer.md)).

## Optional: SFTP put → Lambda marker

```bash
# after apply — see also: terraform output -raw sftp_put_hint
EP=http://127.0.0.1:4566
BUCKET="$(terraform output -raw s3_bucket)"
KEY=build/sftp_id_ed25519
USER="$(terraform output -raw transfer_user)"
echo hello > /tmp/org-path.txt
sftp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -o PreferredAuthentications=publickey -o PasswordAuthentication=no \
  -P "${STACKWRANGLER_SFTP_HOST_PORT:-2222}" "${USER}@127.0.0.1" <<EOF
put /tmp/org-path.txt inbox/hello.txt
bye
EOF
aws --profile local --endpoint-url "$EP" s3 ls "s3://${BUCKET}/inbox/"
# wait a few seconds for the event
aws --profile local --endpoint-url "$EP" s3 cp "s3://${BUCKET}/markers/org-path.txt" -
```

Run the ECS task (does not insert an RDS row by itself — that is #781):

```bash
terraform output -raw run_ecs_hint | bash
```

## Destroy

```bash
terraform destroy -auto-approve
# RDS: may take a minute while the engine container stops
```

## Honest limits / not supported

| Area | Status |
|------|--------|
| S3 console + `aws --profile local s3` same as IaC | Requires [#162](https://github.com/kgz/stackwrangler/issues/162); this example always uses `:4566` |
| SeaweedFS `:8333` | **Out of scope** for org-path — do not wire |
| Transfer `list-*` | May be empty; `describe-*` is authoritative |
| FTPS / FTP / password SFTP | Not supported (SSH keys only) |
| ECS task auto-start / RDS row write | Example registers resources; full hop proof is [#781](https://github.com/kgz/stackwrangler/issues/781) |
| RDS CreateDBInstance stall | [#718](https://github.com/kgz/stackwrangler/issues/718) — use `-var=create_rds=false` |
| Transfer / Lambda CFN types | Moto CFN gaps — this stack uses the Transfer/Lambda APIs via Terraform instead |

See [docs/transfer.md](../../../docs/transfer.md) · [docs/terraform-stackwrangler.md](../../../docs/terraform-stackwrangler.md) · [docs/s3-backends.md](../../../docs/s3-backends.md).
