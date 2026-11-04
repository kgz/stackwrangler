# Terraform: ECS nginx (LocalEmu)

Registers a Fargate-style task that runs **real nginx** via LocalEmu’s Docker ECS backend.

```bash
./bin/awsbox up --force
./smokes/compute/ecs-smoke.sh
```

Smoke: `terraform apply` → `run-task` → curl the host-mapped port.
