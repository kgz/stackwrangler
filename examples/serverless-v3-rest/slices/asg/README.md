# Slice: `asg`

Launch template + `AWS::AutoScaling::AutoScalingGroup` (min 1, max 3) for ECS container instances.

**Smoke:** `./bin/autoscaling-smoke.sh` (create / set-desired-capacity 2 / describe).  
Real instance launch + ECS registration: [#207](https://github.com/kgz/awsl/issues/207). Shared fixture: [#185](https://github.com/kgz/awsl/issues/185).

```bash
# after ./bin/awsbox up — optional CFN deploy of this slice
aws --endpoint-url "$AWSBOX_IAM_ENDPOINT" cloudformation deploy \
  --stack-name awsbox-asg-slice \
  --template-file examples/serverless-v3-rest/slices/asg/template.yaml \
  --parameter-overrides NamePrefix=awsbox-asg VpcId=vpc-… SubnetId=subnet-…
```
