# Prowler against awsbox

Run [Prowler](https://docs.prowler.com/) against LocalEmu so a stack staged on awsbox can get a posture check before real AWS.

## Smoke (preferred)

```bash
./bin/awsbox up          # recreate after compose SERVICES / patch changes
./bin/prowler-smoke.sh
```

The smoke:

1. Installs `prowler==5.45.0` into `.venv-prowler/` if needed
2. Runs under `env -i` with **only** awsbox dummy keys + `AWS_ENDPOINT_URL` (no host `~/.aws`, no real account fallthrough)
3. Uses `http://localhost.localstack.cloud:4566` so S3 Control’s `<account-id>.<host>` form resolves (wildcard DNS → 127.0.0.1)
4. Runs `--scan-unused-services` with a scoped service list (~266 checks: s3, iam, ec2, rds, ssm, cloudwatch, cloudtrail, organizations, backup, awslambda, apigateway, batch, autoscaling)
5. Fails if the count of distinct failing API tokens rises above `testdata/prowler/failing-api-baseline.txt`

## Manual run

```bash
export AWS_ACCESS_KEY_ID=awsbox
export AWS_SECRET_ACCESS_KEY=awsboxawsbox
export AWS_DEFAULT_REGION=us-east-1
export AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566
export AWS_EC2_METADATA_DISABLED=true
# Prefer the smoke’s env -i wrapper so real credentials cannot leak in.
prowler aws --log-level ERROR -f us-east-1
```

Do **not** point `AWS_ENDPOINT_URL` at `http://127.0.0.1:4566` for Prowler — boto3 S3 Control calls become `http://<account-id>.127.0.0.1:4566/...`, which does not resolve.

## Stack pieces

| Piece | Role |
|-------|------|
| `SERVICES` includes `s3control`, `ssm`, `cloudwatch`, `cloudtrail`, `organizations`, `backup`, `batch`, `application-autoscaling`, `dax`, … | Empty-account describe/list for scanners |
| `localemu-patches/s3control_provider.py` | Account public-access + access-point list reads |
| `localemu-patches/init/start.d/10-prowler-stubs.py` | EC2/IAM actions Prowler probes |

Full unscoped catalog scan is still noisy → [#197](https://github.com/kgz/awsl/issues/197). Empty-read services are not full product surfaces → [#198](https://github.com/kgz/awsl/issues/198).

Related: resource policies [#193](https://github.com/kgz/awsl/issues/193), call log [#194](https://github.com/kgz/awsl/issues/194), least privilege [#195](https://github.com/kgz/awsl/issues/195).
