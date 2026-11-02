# Test path rubric (lookup)

**Quick answer:** search this page for the path (e.g. `s3:PutObject`, `AccessDenied`, `SFTP put`).  
If it’s not listed, it is **untested** — add a smoke + row, or a Debt ticket.

Companion tables: [smoke-matrix.md](smoke-matrix.md) (yes/no grid) · [gap-check.md](gap-check.md) (before `done`).  
Smokes live in `smokes/<area>/` ([smokes.md](smokes.md)). `./bin/…` paths below are wrappers.

## Legend

| Kind | Meaning |
|------|---------|
| **happy** | Expected success |
| **sad/authz** | Deliberate deny / missing permission |
| **sad/other** | Missing resource, bad state, tool missing |
| **ui** | Playwright / console interaction |

| Status | Meaning |
|--------|---------|
| covered | Script asserts the outcome |
| thin | Partial / incidental only |
| missing | No automated check |

---

## Path → coverage

| Path / scenario | Kind | Status | How |
|-----------------|------|--------|-----|
| `aws s3` mb/ls/cp/rm (SeaweedFS profile) | happy | covered | `./bin/s3-parity.sh` |
| S3 console buckets/objects | ui | covered | `cd console && yarn test:e2e` / `./bin/e2e.sh` |
| IAM user + deny `s3:ListAllMyBuckets` → AccessDenied | sad/authz | covered | `./bin/iam-access-denied.sh` + IAM console lab |
| OIDC `sub=repo:org/app:environment:prod` assumes tight role | happy | covered | `./bin/oidc-smoke.sh` · [oidc.md](oidc.md) |
| OIDC `sub=repo:org/*` assumes any repo in the org | happy | covered | `./bin/oidc-smoke.sh` |
| OIDC feature ref / other org / wrong aud / bad signature denied | sad/authz | covered | `./bin/oidc-smoke.sh` |
| `iam:PassRole` when `iam:PassedToService=events.amazonaws.com` | happy | covered | `./bin/oidc-smoke.sh` |
| `iam:PassRole` to Step Functions denied by `PassedToService` | sad/authz | covered | `./bin/oidc-smoke.sh` |
| `iam:GetRole` only when `aws:ResourceTag/env=prod` | sad/authz | covered | `./bin/oidc-smoke.sh` |
| `kms:ViaService` / service-origin `aws:SourceArn` | sad/authz | missing | [#223](https://github.com/kgz/awsl/issues/223) |
| Access key → account (`AWSBOX_ACCOUNT_IDS`) | happy | covered | `./bin/multi-account-smoke.sh` · [multi-account.md](multi-account.md) |
| S3 bucket and IAM role in A hidden from B | sad/authz | covered | `./bin/multi-account-smoke.sh` |
| `sts:AssumeRole` role in B trusts `arn:aws:iam::<A>:root` + `sts:ExternalId`; user in A assumes | happy | covered | `./bin/multi-account-smoke.sh` |
| AssumeRole without ExternalId / from account C / user missing `sts:AssumeRole` | sad/authz | covered | `./bin/multi-account-smoke.sh` |
| Trust `StringEquals` `aws:PrincipalOrgID` does not allow | sad/authz | covered | `./bin/multi-account-smoke.sh` |
| Cross-account resource policy Allow | sad/authz | missing | [#233](https://github.com/kgz/awsl/issues/233) |
| Real AWS: deny-user + empty role simulate PutObject | sad/authz | covered | `./bin/aws-parity-iam-denied.sh` (~$0; default creds) · [docs/aws-parity-agent-iam.md](aws-parity-agent-iam.md) |
| Lambda invoke hello (basic role) | happy | covered | `./bin/lambda-smoke.sh` |
| Lambda deploy zip | happy | covered | `./bin/lambda-deploy-smoke.sh` |
| **Lambda role missing `s3:PutObject` → AccessDenied** | sad/authz | covered | `./bin/lambda-authz-smoke.sh` |
| Lambda role trust `aws:SourceAccount` = function account → CreateFunction ok; other account → refused; plain trust ok | happy + sad/authz | covered | `./bin/lambda-trust-condition-smoke.sh` |
| Lambda role trust `aws:SourceArn` = function ARN → CreateFunction ok; other ARN → refused | happy + sad/authz | covered | `./bin/lambda-trust-sourcearn-smoke.sh` |
| REST API import from OpenAPI + `aws_proxy` public route | happy | covered | `./bin/apigw-rest-smoke.sh` · [apigw-rest.md](apigw-rest.md) |
| REST REQUEST authorizer Allow → handler gets context | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST authorizer, no token → 401 | sad/authz | covered | `./bin/apigw-rest-smoke.sh` |
| REST authorizer Deny → 403 | sad/authz | covered | `./bin/apigw-rest-smoke.sh` |
| REST unknown route → 403 | sad/other | covered | `./bin/apigw-rest-smoke.sh` |
| REST custom domain + base-path mapping | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST request via custom domain (root mapping, local DNS) | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST request via custom domain named base path | happy | covered | `./bin/apigw-rest-smoke.sh` |
| REST custom domain unmapped prefix → 403 Forbidden | sad/other | covered | `./bin/apigw-rest-smoke.sh` |
| REST `x-api-key` valid key (minted by Lambda: CreateApiKey + CreateUsagePlanKey + GetUsagePlans) → 200 | happy | covered | `./bin/apigw-usage-plan-smoke.sh` · [apigw-rest.md](apigw-rest.md#api-keys-and-usage-plans) |
| REST `apiKeySource` AUTHORIZER (`usageIdentifierKey`) | happy | covered | `./bin/apigw-usage-plan-smoke.sh` |
| REST `apiKeyRequired` with no key / unknown key / disabled key → 403 | sad/authz | covered | `./bin/apigw-usage-plan-smoke.sh` |
| REST revoked key (DeleteApiKey) → 403 | sad/authz | covered | `./bin/apigw-usage-plan-smoke.sh` |
| REST usage plan throttle (rate/burst) → 429 | sad/other | covered | `./bin/apigw-usage-plan-smoke.sh` |
| REST usage plan quota → 429 | sad/other | covered | `./bin/apigw-usage-plan-smoke.sh` |
| `apigateway:POST` on `/apikeys` denied for a role (CreateApiKey) | sad/authz | covered | `./bin/apigw-usage-plan-smoke.sh` · [#311](https://github.com/kgz/awsl/issues/311) |
| REST usage plan `get-usage` / per-stage throttle | happy | missing | [#309](https://github.com/kgz/awsl/issues/309) |
| REST `HTTP_PROXY` forwards curl `-d` form-urlencoded body bytes unchanged to the backend | happy | covered | `./bin/apigw-proxy-body-smoke.sh` · [apigw-rest.md](apigw-rest.md) · [#364](https://github.com/kgz/awsl/issues/364) |
| REST `HTTP_PROXY` via VPC link to internal NLB to ECS task, path param + injected header at backend | happy | covered | `./bin/apigw-nlb-ecs-smoke.sh` phase A · [apigw-rest.md](apigw-rest.md) |
| REST VPC_LINK to NLB with stopped/unhealthy target → 5xx | sad | covered | `./bin/apigw-nlb-ecs-smoke.sh` phase A |
| ECS awsvpc `describe-tasks` privateIPv4Address inside subnet CIDR and equals container VPC IP; that address reachable on the VPC | happy | covered | `./bin/apigw-nlb-ecs-smoke.sh` · [#268](https://github.com/kgz/awsl/issues/268) |
| REST `HTTP_PROXY` straight to an ECS awsvpc task, path param + injected service token reach backend | happy | covered | `./bin/apigw-nlb-ecs-smoke.sh` |
| REST no token / Deny authorizer: backend receives nothing | sad/authz | covered | `./bin/apigw-nlb-ecs-smoke.sh` |
| REST backend task stopped → API 5xx (AWS 504/503, emulator 500) | sad/other | covered | `./bin/apigw-nlb-ecs-smoke.sh` |
| VPC Lambda → host service by mapped hostname | happy | covered | `./bin/lambda-vpc-smoke.sh` · [lambda-vpc.md](lambda-vpc.md) |
| VPC Lambda → unmapped hostname → ENOTFOUND | sad/other | covered | `./bin/lambda-vpc-smoke.sh` |
| Non-VPC Lambda blocked from private hosts | sad/other | missing | [#187](https://github.com/kgz/awsl/issues/187) |
| Lambda reads per-stage secret → OAuth client-credentials token → POST to external HTTP API | happy | covered | `./bin/lambda-secret-oauth-smoke.sh` |
| Lambda stage isolation (stage=b uses b's secret) and env-var base URL drives the call | happy | covered | `./bin/lambda-secret-oauth-smoke.sh` |
| Lambda role missing `secretsmanager:GetSecretValue` → fails, external API sees no request | sad/authz | covered | `./bin/lambda-secret-oauth-smoke.sh` |
| Lambda OAuth wrong client secret → 401, document not posted | sad/other | covered | `./bin/lambda-secret-oauth-smoke.sh` |
| Lambda role missing other actions | sad/authz | missing | extend `lambda-authz-smoke.sh` / [#150](https://github.com/kgz/awsl/issues/150) |
| ECS run-task + HTTP reachable | happy | covered | `./bin/ecs-smoke.sh` |
| **ECS task role missing `s3:PutObject` → AccessDenied** | sad/authz | covered | `./bin/ecs-authz-smoke.sh` |
| ECS secrets `valueFrom` (ASM JSON key + SSM) via execution role | happy | covered | `./bin/ecs-taskdef-smoke.sh` |
| **ECS execution role deny GetSecretValue → ResourceInitializationError** | sad/authz | covered | `./bin/ecs-taskdef-smoke.sh` |
| ECS `networkMode: host` + portMappings listens on host | happy | covered | `./bin/ecs-taskdef-smoke.sh` |
| ECS `networkMode: host` task role: creds on host 127.0.0.1 (`AWS_CONTAINER_CREDENTIALS_FULL_URI`), endpoint on loopback, no DNAT | happy | covered | `./bin/ecs-host-creds-smoke.sh` |
| ECS host task without a role gets no credentials env; another task id → 404 | sad/authz | covered | `./bin/ecs-host-creds-smoke.sh` |
| ECS container create failure → STOPPED + stoppedReason | sad/other | covered | `./bin/ecs-taskdef-smoke.sh` |
| ECR create-repository + `get-login-password` + docker push/pull `127.0.0.1:5000/<repo>` | happy | covered | `./bin/ecr-smoke.sh` |
| ECS task image `<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>` with `ecr:BatchGetImage` | happy | covered | `./bin/ecr-smoke.sh` |
| **ECS execution role without `ecr:BatchGetImage` → task STOPPED** | sad/authz | covered | `./bin/ecr-smoke.sh` |
| `docker push` of the ECR repositoryUri hostname | happy | missing | [#218](https://github.com/kgz/awsl/issues/218) |
| Lambda `PackageType=Image` ECR pull authz | sad/authz | missing | [#219](https://github.com/kgz/awsl/issues/219) |
| ECS in-container SDK via 169.254 creds URI | sad/authz | thin | [#154](https://github.com/kgz/awsl/issues/154) |
| Public hosted zone + UPSERT A / A-alias / CNAME; `list-resource-record-sets` | happy | covered | `./bin/route53-smoke.sh` · [r53.md](r53.md) |
| Public zone names resolve via `dig @127.0.0.1` inside LocalEmu | happy | covered | `./bin/route53-smoke.sh` |
| Profile `local` `route53 list-hosted-zones` includes the public zone | happy | covered | `./bin/route53-smoke.sh` |
| Private zone create still works alongside public | happy | covered | `./bin/route53-smoke.sh` |
| **`route53:ListHostedZones` explicit deny** (public smoke) | sad/authz | covered | `./bin/route53-smoke.sh` |
| Private zone CNAME → internal NLB resolves and connects from ECS in the associated VPC | happy | covered | `./bin/r53-private-smoke.sh` · [r53-private.md](r53-private.md) |
| Private zone alias to ALB returns the ALB addresses | happy | covered | `./bin/r53-private-smoke.sh` |
| Private zone A and AAAA from the associated VPC | happy | covered | `./bin/r53-private-smoke.sh` |
| EC2 in the associated VPC resolves the private zone | happy | covered | `./bin/r53-private-smoke.sh` |
| Private names from an unassociated VPC | sad/other | covered | `./bin/r53-private-smoke.sh` |
| **`route53:ListHostedZones` explicit deny** | sad/authz | covered | `./bin/r53-private-smoke.sh` |
| Lambda `VpcConfig` private DNS | happy | missing | [#245](https://github.com/kgz/awsl/issues/245) |
| ECS EC2 bridge service behind an internal NLB (2 tasks) | happy | covered | `./bin/ecs-ec2-smoke.sh` |
| ECS task killed → replaced and re-registered in the target group | happy | covered | `./bin/ecs-ec2-smoke.sh` |
| ECS container instance from an ASG + launch template | happy | covered | `./bin/ecs-ec2-smoke.sh` |
| ASG create + set-desired-capacity 2 + describe shows 2 instances | happy | covered | `./bin/autoscaling-smoke.sh` · [batch-stubs.md](batch-stubs.md) |
| Application Auto Scaling register/describe DynamoDB RCU target | happy | covered | `./bin/application-autoscaling-smoke.sh` |
| Batch compute environment + job queue create/describe | happy | covered | `./bin/batch-smoke.sh` |
| Elastic Beanstalk create/describe application | happy | covered | `./bin/elasticbeanstalk-smoke.sh` |
| App Runner list-services / list-connections (empty stub) | happy | covered | `./bin/apprunner-smoke.sh` |
| Batch / Beanstalk / App Runner / ASG authz deny | sad/authz | missing | [#334](https://github.com/kgz/awsl/issues/334) |
| App Runner CreateService + traffic | happy | missing | [#335](https://github.com/kgz/awsl/issues/335) |
| Batch SubmitJob dataplane | happy | missing | [#335](https://github.com/kgz/awsl/issues/335) |
| Elastic Beanstalk environment provision | happy | missing | [#335](https://github.com/kgz/awsl/issues/335) |
| ECS `CODE_DEPLOY` service starts blue tasks behind the listener | happy | covered | `./bin/ecs-ec2-smoke.sh` |
| ECS CodeDeploy blue/green: v2 on green, listener swap, blue stopped | happy | covered | `./bin/ecs-ec2-smoke.sh`, `./bin/codedeploy-smoke.sh` |
| ECS CodeDeploy revision names a missing task definition → Failed | sad/other | covered | `./bin/ecs-ec2-smoke.sh`, `./bin/codedeploy-smoke.sh` |
| CodeDeploy Lambda app + canary deployment config + create-deployment Succeeded | happy | covered (control plane) | `./bin/codedeploy-smoke.sh` |
| CodeDeploy Lambda canary alias weight shift | happy | missing | [#340](https://github.com/kgz/awsl/issues/340) |
| CodeDeploy deny create-deployment / create-application | sad/authz | missing | [#341](https://github.com/kgz/awsl/issues/341) |
| **ECS deny `ecs:CreateService` → AccessDenied** | sad/authz | covered | `./bin/ecs-ec2-smoke.sh` |
| EC2 running + user-data file | happy | covered | `./bin/ec2-smoke.sh` |
| EC2 IMDSv2 instance-profile reads secret | happy | covered | `./bin/ec2-imds-smoke.sh` |
| EC2 instance-profile missing GetSecretValue → AccessDenied | sad/authz | covered | `./bin/ec2-imds-smoke.sh` |
| SSM SendCommand AWS-RunShellScript returns stdout | happy | covered | `./bin/ec2-imds-smoke.sh` |
| SSM SendCommand without ssm:SendCommand → AccessDenied | sad/authz | covered | `./bin/ec2-imds-smoke.sh` |
| Private subnet with no `0.0.0.0/0` cannot reach a public host | sad/other | covered | `./bin/vpc-routing-smoke.sh` · [vpc-routing.md](vpc-routing.md) |
| Private subnet reaches a public host via an HTTP proxy over peering | happy | covered | `./bin/vpc-routing-smoke.sh` |
| VPC peering both ways; deleting one route breaks that direction | sad/other | covered | `./bin/vpc-routing-smoke.sh` · Lambda: `./bin/vpc-egress-smoke.sh` |
| NAT gateway `0.0.0.0/0` restores egress | happy | covered | `./bin/vpc-routing-smoke.sh` |
| VPC Lambda private subnet: public host blocked; S3 only via GW endpoint; peer OK; IGW restores; routes replay after restart | happy + sad/other | covered | `./bin/vpc-egress-smoke.sh` · [vpc-routing.md](vpc-routing.md) · slice `examples/serverless-v3-rest/slices/egress/` |
| Attach/DetachInternetGateway keeps the same `localemu-vpc-*` Docker network id | happy | covered | `./bin/vpc-egress-smoke.sh` · [#386](https://github.com/kgz/awsl/issues/386) |
| ECS `bridge` task joins subnet VPC (`localemu-vpc-*`) and keeps default bridge | happy | covered | `./bin/vpc-egress-bridge-check.sh` (from `vpc-egress-smoke.sh`) · [#230](https://github.com/kgz/awsl/issues/230) |
| Private ECS task reaches a public host only through an egress proxy (`HTTP_PROXY`) | happy | covered | `./bin/egress-proxy-smoke.sh` |
| Same task with proxy env unset cannot reach the public host directly | sad/other | covered | `./bin/egress-proxy-smoke.sh` |
| Egress proxy allowlist refuses another host (task sees 403) | sad/authz | covered | `./bin/egress-proxy-smoke.sh` |
| Private ECS task reaches the emulator endpoint without the proxy (`NO_PROXY`) | happy | covered | `./bin/egress-proxy-smoke.sh` |
| Private ECS task reaches the emulator endpoint without the proxy (`NO_PROXY`) | happy | covered (currently fails) | `./bin/egress-proxy-smoke.sh` |
| Non-root image in private subnet (no default route) cannot reach a public host | sad/other | covered | `./bin/egress-proxy-smoke.sh` · [#270](https://github.com/kgz/awsl/issues/270) |
| ECS `awsvpc` task is not on the default docker bridge (`ip route` / networks) | sad/other | covered | `./bin/egress-proxy-smoke.sh` · [#271](https://github.com/kgz/awsl/issues/271) |
| Private ECS task reaches the emulator endpoint without the proxy (`NO_PROXY`) | happy | covered (currently fails) | `./bin/egress-proxy-smoke.sh` · [#269](https://github.com/kgz/awsl/issues/269) |
| Interface VPCE `PrivateDnsEnabled`: service hostname resolves in-VPC and call reaches awsbox (ecr/logs/ssm/sts/ecs) | happy | covered | `./bin/vpce-private-dns-smoke.sh` · [vpce-private-dns.md](vpce-private-dns.md) |
| Same service hostname from another VPC does not resolve to that endpoint IP | sad/other | covered | `./bin/vpce-private-dns-smoke.sh` |
| Gateway endpoint prefix-list route | sad/other | covered | `./bin/vpc-egress-smoke.sh` · [#230](https://github.com/kgz/awsl/issues/230) |
| SG allows TCP only from SG A: EC2 and ECS in A connect, B refused | happy | covered | `./bin/sg-enforcement-smoke.sh` · [sg-enforcement.md](sg-enforcement.md) |
| SG rule revoke/authorize updates a running target | sad/other | covered | `./bin/sg-enforcement-smoke.sh` |
| Prefix list and CIDR allow one address and refuse another | happy | covered | `./bin/sg-enforcement-smoke.sh` |
| RDS on a subnet allows 5432 only from SG A | happy | covered | `./bin/sg-enforcement-smoke.sh` |
| NLB path sees client IP at the target SG | happy | missing | [#236](https://github.com/kgz/awsl/issues/236) |
| VPC Lambda traffic filtered by its security groups | sad/other | missing | [#237](https://github.com/kgz/awsl/issues/237) |
| Console label for a VPC ID and an NLB ARN glob | happy | covered | `./bin/labels-smoke.sh` · [labels.md](labels.md) |
| `GET /_awsl/labels` | happy | covered | `./bin/labels-smoke.sh` |
| Labels file missing → empty `GET /_awsl/labels` and no console label | sad/other | covered | `./bin/labels-smoke.sh` |
| NLB TCP :443 → two instance targets | happy | covered | `./bin/elbv2-smoke.sh` · [elbv2.md](elbv2.md) |
| Internal NLB :10080 → two target ports; closed on the edge address | happy | covered | `./bin/elbv2-smoke.sh` |
| NLB target sees the client source IP | happy | covered | `./bin/elbv2-smoke.sh` |
| NLB TLS listener forwards after termination | happy | covered | `./bin/elbv2-smoke.sh` |
| ALB host + path → TG-A, other requests → default TG | happy | covered | `./bin/elbv2-smoke.sh` |
| LB DNS from a VPC instance and from the host | happy | covered | `./bin/elbv2-smoke.sh` |
| Unhealthy NLB target receives no new connections | sad/other | covered | `./bin/elbv2-smoke.sh` |
| **ELBv2 deny-user CreateLoadBalancer → AccessDenied** | sad/authz | covered | `./bin/elbv2-smoke.sh` |
| ELBv2 console list / target health | ui | missing | [#241](https://github.com/kgz/awsl/issues/241) |
| ELBv2 TLS listener presents its ACM certificate | happy | missing | [#242](https://github.com/kgz/awsl/issues/242) |
| ACM request DNS-validated cert + describe/list | happy | covered | `./bin/acm-smoke.sh` · [acm.md](acm.md) |
| ACM import-certificate | happy | covered | `./bin/acm-smoke.sh` |
| ACM ARN on API GW custom domain | happy | covered | `./bin/acm-smoke.sh` |
| ACM ARN stored on ALB HTTPS listener | happy | covered | `./bin/acm-smoke.sh` |
| **ACM deny-user RequestCertificate → AccessDenied** | sad/authz | covered | `./bin/acm-smoke.sh` |
| ACM console | ui | missing | [#333](https://github.com/kgz/awsl/issues/333) |
| ELBv2 HTTP health check treats 500 as unhealthy | sad/other | missing | [#243](https://github.com/kgz/awsl/issues/243) |
| WAFv2 create WebACL + associate API GW stage; get/list association | happy | covered | `./bin/waf-smoke.sh` · [waf.md](waf.md) |
| Network Firewall create rule group + firewall policy; describe/list | happy | covered | `./bin/network-firewall-fms-smoke.sh` · [network-firewall.md](network-firewall.md) |
| Firewall Manager put/get/list policy stub | happy | covered | `./bin/network-firewall-fms-smoke.sh` · [network-firewall.md](network-firewall.md) |
| Network Firewall packet filtering | happy | missing | [#441](https://github.com/kgz/stackwrangler/issues/441) · [network-firewall.md](network-firewall.md) |
| Firewall Manager org policy enforcement | happy | missing | [#442](https://github.com/kgz/stackwrangler/issues/442) · [network-firewall.md](network-firewall.md) |
| **WAFv2 deny-user CreateWebACL → AccessDenied** | sad/authz | covered | `./bin/waf-authz-smoke.sh` |
| WAFv2 rule evaluation blocks/allows HTTP | happy | missing | [#326](https://github.com/kgz/awsl/issues/326) · [waf.md](waf.md) |
| WAFv2 console | ui | missing | [#324](https://github.com/kgz/awsl/issues/324) |
| CFN `AWS::WAFv2::WebACL` / Association deploy | happy | missing | [#325](https://github.com/kgz/awsl/issues/325) |
| CFN/CDK/SAM deploy S3+Lambda write | happy | covered | `./bin/{cfn,cdk,sam}-smoke.sh` |
| Serverless v3 deploy → `/public/health` → redeploy → remove | happy | covered | `./bin/serverless-v3-smoke.sh` · [serverless-awsbox.md](serverless-awsbox.md) |
| Serverless v3 `${ssm:…}` + RestApi OpenAPI `Body` resource | happy | covered | `./bin/serverless-v3-smoke.sh` |
| Serverless v3 http-event REQUEST authorizer | happy | missing | [#328](https://github.com/kgz/awsl/issues/328) |
| Serverless v3 smoke deliberate failure | sad/other | missing | [#330](https://github.com/kgz/awsl/issues/330) |
| CFN failed create → `ROLLBACK_COMPLETE`, created resources removed, delete + recreate | sad/other | covered | `./bin/cfn-lifecycle-smoke.sh` |
| CFN delete-stack removes resources; `DeletionPolicy: Retain` kept | happy | covered | `./bin/cfn-lifecycle-smoke.sh` |
| CFN failed update → `UPDATE_ROLLBACK_COMPLETE` (not `UPDATE_COMPLETE`) | sad/other | covered | `./bin/cfn-lifecycle-smoke.sh` |
| CFN failed update reverts in-place resource changes | sad/other | missing | [#228](https://github.com/kgz/awsl/issues/228) |
| CFN `DeletionPolicy: Snapshot` | sad/other | missing | [#228](https://github.com/kgz/awsl/issues/228) |
| Real AWS CFN S3+Lambda (same template) | happy | covered | `./bin/aws-parity-cfn-s3-lambda.sh` · [aws-parity-cfn.md](aws-parity-cfn.md) |
| Real AWS CFN empty Lambda role → AccessDenied | sad/authz | covered | `./bin/aws-parity-cfn-authz.sh` |
| Real AWS HF cheap: DDB GSI/condition, schedule→Lambda, REST Deny 403, API key/usage plan, S3 GW VPCE | happy+sad | covered | `./bin/aws-parity-hf-cheap.sh` (~$0–cents; ask before real) · [aws-parity-hf-cheap.md](aws-parity-hf-cheap.md) |
| Real AWS HF skipped: WAF, R53 zone, ACM without DNS, Transfer, CodeDeploy target stack, Batch/ASG compute | — | skipped (cost) | [aws-parity-hf-cheap.md](aws-parity-hf-cheap.md) skipped gaps |
| Prowler aws scan (isolated, scoped unused-services) | happy | covered | `./bin/prowler-smoke.sh` · [prowler.md](prowler.md) |
| Prowler failing-API count ≤ baseline (ratchet) | sad/other | covered | `./bin/prowler-smoke.sh` |
| S3 Control GetPublicAccessBlock / ListAccessPoints (account) | happy | covered | `./bin/prowler-smoke.sh` spot-check |
| SQS send/receive/delete | happy | covered | `./bin/sqs-smoke.sh` |
| SQS MessageRetentionPeriod > 14d → InvalidAttributeValue | sad/other | covered | `./bin/sqs-smoke.sh` |
| **SQS deny-user SendMessage → AccessDenied** | sad/authz | covered | `./bin/sqs-authz-smoke.sh` |
| SQS → Lambda event source mapping invokes Lambda, message deleted | happy | covered | `./bin/sqs-lambda-dlq-smoke.sh` |
| SQS redrive (maxReceiveCount 2) to DLQ on Lambda failure | happy | covered | `./bin/sqs-lambda-dlq-smoke.sh` |
| Lambda role without SQS read perms → CreateEventSourceMapping refused | sad/authz | covered | `./bin/sqs-lambda-dlq-smoke.sh` |
| SQS VisibilityTimeout < function timeout → CreateEventSourceMapping refused | sad/other | covered | `./bin/sqs-lambda-dlq-smoke.sh` |
| ESM MaximumConcurrency < 2 → CreateEventSourceMapping refused | sad/other | covered | `./bin/sqs-lambda-dlq-smoke.sh` |
| Lambda role loses SQS poll perms after ESM create → polling stops / LastProcessingResult or State | sad/authz | covered | `./bin/sqs-lambda-dlq-smoke.sh` |
| Lambda role re-granted SQS poll perms → ESM resumes and queued message consumed | happy | covered | `./bin/sqs-lambda-dlq-smoke.sh` |
| SNS create/publish | happy | covered | `./bin/sns-smoke.sh` |
| SNS deny Publish | sad/authz | covered | `./bin/sns-authz-smoke.sh` |
| SNS MaximumMessageSize CreateTopic/Set; default >256 KiB reject; 300 KiB–1 MiB publish + SQS raw | happy/sad | covered | `./bin/sns-max-message-size-smoke.sh` |
| SNS large-topic (>256 KiB) subscribe: http/email/sms/application → InvalidParameter; sqs/lambda/firehose ok; Set refused with http sub | sad/happy | covered | `./bin/sns-max-message-size-smoke.sh` |
| SNS → SQS fan-out (envelope, raw delivery, filter policy) | happy | covered | `./bin/sns-sqs-fanout-smoke.sh` |
| SNS → SQS queue policy not allowing topic / missing policy → not delivered; unsubscribe stops delivery | sad/authz | covered | `./bin/sns-sqs-fanout-smoke.sh` |
| SNS → SQS with `KmsMasterKeyId=alias/aws/sqs` → not delivered | sad | covered | `./bin/sns-sqs-fanout-smoke.sh` |
| SNS → SQS queue CMK without `sns.amazonaws.com` `kms:GenerateDataKey` + `kms:Decrypt` → not delivered | sad/authz | covered | `./bin/sns-sqs-fanout-smoke.sh` |
| SNS → SQS queue CMK whose key policy Allows `sns.amazonaws.com` those actions → delivered | happy | covered | `./bin/sns-sqs-fanout-smoke.sh` |
| EventBridge put-events + rule | happy | covered | `./bin/events-smoke.sh` |
| EventBridge deny PutEvents | sad/authz | covered | `./bin/events-authz-smoke.sh` |
| EventBridge `rate(1 minute)` rule invokes Lambda target (CFN `Events::Rule`) | happy | covered | `./bin/events-schedule-smoke.sh` |
| EventBridge `disable-rule` stops scheduled invocations | happy | covered | `./bin/events-schedule-smoke.sh` |
| EventBridge rule → Lambda without `lambda:InvokeFunction` (`events.amazonaws.com`) → no invocation | sad/authz | covered | `./bin/events-schedule-smoke.sh` |
| EventBridge `cron(* * * * ? *)` rule invokes Lambda target (other cron/rate forms: [#317](https://github.com/kgz/awsl/issues/317)) | happy | covered | `./bin/events-schedule-smoke.sh` |
| DynamoDB put/get | happy | covered | `./bin/dynamodb-smoke.sh` |
| DynamoDB deny PutItem | sad/authz | covered | `./bin/dynamodb-authz-smoke.sh` |
| DynamoDB table with GSI + TTL deployed via CloudFormation (serverless slice) | happy | covered | `./bin/dynamodb-depth-smoke.sh` |
| DynamoDB GSI query, table query, scan with filter | happy | covered | `./bin/dynamodb-depth-smoke.sh` |
| DynamoDB UpdateItem expression (`SET`, `if_not_exists`, `REMOVE`) | happy | covered | `./bin/dynamodb-depth-smoke.sh` |
| DynamoDB TransactWriteItems commit | happy | covered | `./bin/dynamodb-depth-smoke.sh` |
| DynamoDB TTL expiry removes item from table and GSI | happy | covered | `./bin/dynamodb-depth-smoke.sh` (sweep via `DELETE /_aws/dynamodb/expired`, LocalEmu-only) |
| DynamoDB duplicate conditional put / failed update condition → `ConditionalCheckFailedException` | sad/other | covered | `./bin/dynamodb-depth-smoke.sh` |
| DynamoDB cancelled transaction → `TransactionCanceledException`, no partial write | sad/other | covered | `./bin/dynamodb-depth-smoke.sh` |
| DynamoDB Allow on index ARN only / table ARN only / Deny on index ARN | sad/authz | covered | `./bin/dynamodb-depth-smoke.sh` |
| DynamoDB Batch*/Transact* under table-scoped policy | sad/authz | missing | [#306](https://github.com/kgz/awsl/issues/306) |
| DynamoDB `aws:ResourceTag` on index ARN | sad/authz | missing | [#307](https://github.com/kgz/awsl/issues/307) |
| Step Functions Pass execution | happy | covered | `./bin/sfn-smoke.sh` |
| Step Functions deny StartExecution | sad/authz | covered | `./bin/sfn-authz-smoke.sh` |
| Secrets create/get | happy | covered | `./bin/secrets-smoke.sh` |
| Secrets deny GetSecretValue | sad/authz | covered | `./bin/secrets-authz-smoke.sh` |
| Secret resource policy explicit deny beats Lambda-role IAM Allow (`GetSecretValue`, `DescribeSecret`) | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| KMS encrypt/decrypt | happy | covered | `./bin/kms-smoke.sh` |
| KMS deny Decrypt | sad/authz | covered | `./bin/kms-authz-smoke.sh` |
| KMS key policy delegates to IAM and role Encrypt/Decrypt/GenerateDataKey succeeds | happy | covered | `./bin/resource-policy-smoke.sh` |
| KMS key policy without IAM delegation denies a role IAM allows | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| KMS key policy explicit deny Encrypt | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| S3 bucket policy explicit deny GetObject/ListBucket | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| Secrets Manager CMK GetSecretValue follows key policy | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| Secrets Manager CreateSecret/PutSecretValue with a CMK follows key policy | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| SSM SecureString GetParameter/PutParameter follows CMK key policy | sad/authz | covered | `./bin/resource-policy-smoke.sh` |
| Cross-account resource policy (identity and resource must both allow) | sad/authz | missing | [#233](https://github.com/kgz/awsl/issues/233) · needs [#213](https://github.com/kgz/awsl/issues/213) |
| Kinesis put/get | happy | covered | `./bin/kinesis-smoke.sh` |
| Kinesis deny PutRecord | sad/authz | covered | `./bin/kinesis-authz-smoke.sh` |
| Logs deny PutLogEvents | sad/authz | covered | `./bin/logs-authz-smoke.sh` |
| API GW deny CreateApi | sad/authz | covered | `./bin/apigw-authz-smoke.sh` |
| EC2 deny RunInstances | sad/authz | covered | `./bin/ec2-authz-smoke.sh` |
| CFN console list/detail tabs | ui | covered | `console/e2e/cfn-stacks.spec.ts` |
| Built-service list chrome matches OD mocks, disabled controls explained | ui | covered | `console/e2e/services-chrome.spec.ts` |
| Transfer / RDS / ECS / VPC / load balancer detail pages (tabs, sections, disabled controls) | ui | covered | `console/e2e/services-detail.spec.ts` |
| CFN Create/Update in console | ui | missing | [#93](https://github.com/kgz/awsl/issues/93)–[#95](https://github.com/kgz/awsl/issues/95) |
| Transfer create-server / create-user API | happy | covered | `./bin/transfer-smoke.sh` |
| SFTP SSH-key put → LocalEmu S3 (+ ObjectCreated Lambda) | happy | covered | `./bin/transfer-key-smoke.sh` |
| SFTP key put → S3 (short dataplane) | happy | covered | `./bin/transfer-dataplane-smoke.sh` |
| `awsbox up` while this checkout's beta `atmoz/sftp` container holds the emulator port | sad | covered | `./bin/transfer-sftp-port-smoke.sh` |
| `awsbox up` while another project or process holds the SFTP host port | sad | covered | `./bin/transfer-sftp-port-smoke.sh` |
| **Wrong SSH key rejected (no password fallback)** | sad/authz | covered | `./bin/transfer-key-smoke.sh` |
| **Transfer empty role → simulate PutObject deny** | sad/authz | covered | `./bin/transfer-authz-smoke.sh` |
| Transfer under-permissioned role (SFTP bytes) | sad/authz | missing | [#141](https://github.com/kgz/awsl/issues/141) |
| Transfer create/describe/update/delete-connector, test-connection | happy | covered | `./bin/transfer-connector-smoke.sh` |
| Transfer start-file-transfer: S3 object → remote SFTP (Lambda-created tenant connector) | happy | covered | `./bin/transfer-connector-smoke.sh` |
| Transfer connector events in CloudWatch Logs | happy | covered | `./bin/transfer-connector-smoke.sh` |
| **Transfer connector access role without `s3:GetObject`** | sad/authz | covered | `./bin/transfer-connector-smoke.sh` |
| **Transfer connector access role without secret read / `kms:Decrypt`** | sad/authz | covered | `./bin/transfer-connector-smoke.sh` |
| **Transfer connector access role trust scoped to another account** | sad/authz | covered | `./bin/transfer-connector-smoke.sh` |
| **Transfer create-connector without `iam:PassRole`** | sad/authz | covered | `./bin/transfer-connector-smoke.sh` |
| Transfer connector wrong trusted host key | sad | covered | `./bin/transfer-connector-smoke.sh` |
| Transfer connector retrieve / AS2 | happy | missing | [#314](https://github.com/kgz/awsl/issues/314) |
| Transfer under-permissioned role (SFTP bytes) | sad/authz | missing | [#322](https://github.com/kgz/awsl/issues/322) |
| RDS Postgres SQL round-trip | happy | covered | `./bin/rds-smoke.sh` |
| **RDS wrong password → auth denied** | sad/authz | covered | `./bin/rds-authz-smoke.sh` |
| RDS IAM DB auth | sad/authz | missing | [#145](https://github.com/kgz/awsl/issues/145) |
| RDS MySQL instance + managed secret | happy | covered | `./bin/rds-mysql-smoke.sh` |
| **RDS MySQL wrong password → access denied** | sad/authz | covered | `./bin/rds-mysql-smoke.sh` |
| Aurora MySQL writer SQL via `rds!` secret | happy | covered | `./bin/rds-mysql-smoke.sh` |
| **Aurora MySQL reader rejects writes** | sad/other | covered | `./bin/rds-mysql-smoke.sh` |
| Aurora MySQL failover | sad/other | missing | [#225](https://github.com/kgz/awsl/issues/225) |
| Logs create/put/get | happy | covered | `./bin/logs-smoke.sh` |
| API GW HTTP create/invoke | happy | covered | `./bin/apigw-smoke.sh` |
| **Seaweed vs LocalEmu S3 are separate stores** | sad/other | covered | `./bin/s3-dual-endpoint-smoke.sh` · [s3-backends.md](s3-backends.md) |
| `awsl apply` synthetic VPC/subnet/SG ids + CIDRs | happy | covered | `./bin/mirror-smoke.sh` · [mirror.md](mirror.md) |
| `awsl apply` fixture tags (Name, CDK subnet, Tier=private RT) + TF data sources | happy | covered | `./bin/mirror-tags-smoke.sh` · [mirror.md](mirror.md) |
| `awsl mirror --out` inside the repo (not gitignored) | sad/other | covered | `./bin/mirror-smoke.sh` |
| `awsl apply` non-local endpoint | sad/other | covered | `./bin/mirror-smoke.sh` |
| Real-account `awsl mirror` read (Describe/List/Get only) | happy | missing | [#220](https://github.com/kgz/awsl/issues/220) |
| Create VPC/subnet/SG with `_custom_id_` + account id in OwnerId/STS/ARNs | happy | covered | `./bin/custom-id-smoke.sh` · [custom-ids.md](custom-ids.md) |
| Create route table, IGW, peering, instance, LB/TG suffix, REST/HTTP API, hosted zone, ECS cluster ARN with `_custom_id_` | happy | covered | `./bin/custom-id-smoke.sh` |
| `_custom_id_` value fails the id format check | sad/other | covered | `./bin/custom-id-smoke.sh` |
| Terraform bootstrap state bucket + DynamoDB lock, then remote-state apply | happy | covered | `AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./bin/terraform-backend-smoke.sh` · [terraform-awsbox.md](terraform-awsbox.md) |
| Terraform second plan no-change with S3 backend on LocalEmu | happy | covered | `AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./bin/terraform-backend-smoke.sh` |
| Terraform backend smoke canary: real AWS STS succeeds → abort | sad/other | covered | `AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./bin/terraform-backend-smoke.sh` |

---

## How to run the suite (local)

```bash
./bin/awsbox up --force
./bin/e2e.sh                    # includes IAM deny + S3 parity + playwright subset
./bin/lambda-smoke.sh           # happy
./bin/lambda-authz-smoke.sh     # sad/authz
./bin/multi-account-smoke.sh    # key→account, AssumeRole, hidden bucket
./bin/transfer-key-smoke.sh
./bin/transfer-dataplane-smoke.sh
./bin/transfer-connector-smoke.sh
./bin/rds-smoke.sh              # needs psql
./bin/rds-mysql-smoke.sh        # needs mysql
# …add others as you touch a surface
```

Wire new paths here **in the same PR** as the smoke. If deferred → Debt ticket + link in the Status column.
| Real AWS batch10 messaging/data/crypto | happy+sad | covered | `./bin/aws-parity-batch10.sh` |
