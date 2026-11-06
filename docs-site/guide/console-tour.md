# Console tour

Screenshots from a **local** stackwrangler console (grey rose theme, real data after `./bin/stackwrangler up`). These are not AWS Management Console recon images.

Assets live in shared [`docs/assets/console/`](https://github.com/kgz/stackwrangler/tree/main/docs/assets/console) (also used by the public README work).

## Home — S3 buckets

General purpose buckets UI talks to **SeaweedFS** on `:8333`.

![S3 buckets](/assets/console/home-s3-buckets.png)

## Lambda

Functions list against LocalEmu (`:4566`). Create and detail (Monaco) are wired for the happy path.

![Lambda functions](/assets/console/lambda-functions.png)

## CloudFormation

Stacks console for the local CFN path used by CDK / SAM / examples. Update stack (template replace) and change sets (list / detail / execute / delete) are wired; Create stack remains [#93](https://github.com/kgz/awsl/issues/93).

![CloudFormation stacks](/assets/console/cloudformation-stacks.png)

## ECS

Clusters / services / tasks — **Partial** depth; good enough to see what is running locally.

![ECS clusters](/assets/console/ecs-clusters.png)

## EC2

Instances list — **Partial** console depth.

![EC2 instances](/assets/console/ec2-instances.png)

## Honest empty chrome

Specialty bucket types are **console chrome** only — empty states, not a fake data plane.

![Specialty buckets empty state](/assets/console/empty-specialty-buckets.png)

## Architecture map

Experimental live topology map — coming with [#389](https://github.com/kgz/stackwrangler/issues/389) (not on `main` yet). Add a screenshot here once that console page ships; do not substitute AWS recon PNGs from `design/.../refs/`.

## Try it

```bash
./bin/stackwrangler up
./bin/stackwrangler console
```

Then open http://127.0.0.1:3000 and walk S3 → Lambda → ECS / EC2 → an empty specialty page.
