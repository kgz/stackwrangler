# Prowler against awsbox

Run [Prowler](https://docs.prowler.com/) against LocalEmu so a stack staged on awsbox can get a posture check before real AWS.

## Smoke (preferred)

```bash
./bin/awsbox up
./bin/awsbox-hosts check    # or: ./bin/awsbox hosts check
# if missing: ./bin/awsbox-hosts apply   # or add the printed line yourself
./bin/prowler-smoke.sh
```

The smoke:

1. Installs `prowler==5.45.0` into `.venv-prowler/` if needed (`uv venv`/`uv pip` when `uv` is on PATH; else `python3 -m venv` — needs distro `python3-venv` on Debian/Ubuntu/WSL). Removes a half-built venv if install fails.
2. Runs under `env -i` with **only** awsbox dummy keys + `AWS_ENDPOINT_URL` (no host `~/.aws`, no real account fallthrough) — including the S3 Control spot-checks
3. Defaults to `http://awsbox.localhost:4566` so S3 Control’s `<account-id>.<host>` form can resolve. Override with `AWSBOX_PROWLER_ENDPOINT`
4. Runs `--scan-unused-services` with a scoped service list (~266 checks: s3, iam, ec2, rds, ssm, cloudwatch, cloudtrail, organizations, backup, awslambda, apigateway, batch, autoscaling)
5. Fails if any **new** failing API token appears vs `testdata/prowler/failing-api-baseline.txt` (set diff, not only count)
6. Checks the running LocalEmu image matches `localemu-patches/IMAGE_DIGEST` (compose pins the same digest)

## Hosts for S3 Control (`awsbox.localhost`)

boto3 addresses S3 Control as `http://<account-id>.<endpoint-host>:4566/…`. That host must resolve to loopback. We use `awsbox.localhost` (not a third-party DNS name).

On many hosts, RFC 6761 synthesises `*.localhost` → `127.0.0.1`. **WSL2 and some minimal Debian/Ubuntu images do not** (`hosts: files dns` in `nsswitch.conf`, no synthetic localhost). Then:

```bash
./bin/awsbox-hosts print
# → 127.0.0.1 awsbox.localhost 000000000000.awsbox.localhost # awsbox-managed (prowler / s3control)

./bin/awsbox-hosts apply    # sudo tee -a /etc/hosts
```

`./bin/awsbox up` warns when the names do not resolve (stack still starts; only Prowler/S3 Control virtual-host needs them).

### WSL notes

- WSL may **regenerate** `/etc/hosts` on start. Either:
  - set in `/etc/wsl.conf`:
    ```ini
    [network]
    generateHosts = false
    ```
    then `wsl --shutdown` and re-apply the line, or
  - add the same line to the **Windows** hosts file  
    `C:\Windows\System32\drivers\etc\hosts`  
    (WSL copies Windows hosts into the distro when `generateHosts` is on).
- Override without hosts: `AWSBOX_PROWLER_ENDPOINT=http://…` pointing at any name that supports `<account-id>.<host>` (e.g. a local dnsmasq wildcard).

## Manual run

```bash
export AWS_ACCESS_KEY_ID=awsbox
export AWS_SECRET_ACCESS_KEY=awsboxawsbox
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL=http://awsbox.localhost:4566
export AWS_EC2_METADATA_DISABLED=true
# Prefer the smoke’s env -i wrapper so real credentials cannot leak in.
prowler aws --log-level ERROR -f us-east-1 --scan-unused-services
```

Do **not** point `AWS_ENDPOINT_URL` at `http://127.0.0.1:4566` for Prowler — boto3 S3 Control calls become `http://<account-id>.127.0.0.1:4566/...`, which does not resolve.

## Stack pieces

| Piece | Role |
|-------|------|
| `SERVICES` includes `s3control`, `ssm`, `cloudwatch`, `cloudtrail`, `organizations`, `backup`, `batch`, `application-autoscaling`, `autoscaling`, `elasticbeanstalk`, `apprunner`, `dax`, … | Empty-account describe/list for scanners · stubs [#83](https://github.com/kgz/awsl/issues/83) |
| `localemu-patches/s3control_provider.py` | Account Get/PutPublicAccessBlock + access-point lists (AWS-shaped empty get) |
| `localemu-patches/init/start.d/10-prowler-stubs.py` | EC2/IAM/RDS/SSM/Backup actions Prowler probes |
| `localemu-patches/ecs_task_manager.py` / `ecs_provider.py` | ECS secrets `valueFrom`, host ports, failed-start status (#201) |
| `localemu-patches/ecs_ec2_services.py` | EC2 container instances, service replacement, bridge target registration, CodeDeploy blue/green (#207) + Lambda deploy Succeeded control plane (#98) |
| `localemu/localemu@sha256:…` (pinned) | Avoid silent break of file mounts on `:latest` drift |
| `./bin/awsbox-hosts` | Check / print / apply loopback hosts for S3 Control |

Unset account public-access block returns `NoSuchPublicAccessBlockConfiguration` (like AWS). Use `put-public-access-block` to stage the “configured” case for S3 public-access checks.

Full unscoped catalog scan is still noisy → [#197](https://github.com/kgz/awsl/issues/197). Empty-read services are not full product surfaces → [#198](https://github.com/kgz/awsl/issues/198). Persistence across recreate → [#200](https://github.com/kgz/awsl/issues/200).

Related: resource policies [#193](https://github.com/kgz/awsl/issues/193), call log [#194](https://github.com/kgz/awsl/issues/194), least privilege [#195](https://github.com/kgz/awsl/issues/195).
