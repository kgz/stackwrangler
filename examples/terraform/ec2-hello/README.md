# Terraform: EC2 hello (LocalEmu)

Launches a **real Docker-backed** EC2 instance (`ami-ubuntu-22.04`) with user-data that writes `/tmp/hello.txt`.

```bash
./bin/awsbox up --force
./smokes/compute/ec2-smoke.sh
```

Host cannot always reach the private IP; smoke verifies via the Docker container.
