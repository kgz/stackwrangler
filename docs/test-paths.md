# Test path rubric (lookup)

**Quick answer:** search this page for the path (e.g. `s3:PutObject`, `AccessDenied`, `SFTP put`).  
If it’s not listed, it is **untested** — add a smoke + row, or a Debt ticket.

Companion tables: [smoke-matrix.md](smoke-matrix.md) (yes/no grid) · [gap-check.md](gap-check.md) (before `done`).  
Smokes live in `smokes/<area>/` ([smokes.md](smokes.md)). Paths below are `./smokes/<area>/…`.

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
| Public path: cold dir + copied `install/stackwrangler up` (no monorepo compose) | happy | covered | `./smokes/platform/docker-image-install-smoke.sh` · [docker-install.md](docker-install.md) |
| Public path: console HTTP on release nginx image | happy | covered | `./smokes/platform/docker-image-install-smoke.sh` |
| Public path: `aws --profile local` sts + s3 ls after image up | happy | covered | `./smokes/platform/docker-image-install-smoke.sh` |
| Public path: orchestrator `up` without `/var/run/docker.sock` | sad/other | covered | `./smokes/platform/docker-image-install-smoke.sh` |
| `aws s3` mb/ls/cp/rm (SeaweedFS profile) | happy | covered | `./smokes/s3/s3-parity.sh` |
| S3 console buckets/objects | ui | covered | `cd console && yarn test:e2e` / `./bin/e2e.sh` |
| IAM user + deny `s3:ListAllMyBuckets` → AccessDenied | sad/authz | covered | `./smokes/security/iam-access-denied.sh` + IAM console lab |
| OIDC `sub=repo:org/app:environment:prod` assumes tight role | happy | covered | `./smokes/security/oidc-smoke.sh` · [oidc.md](oidc.md) |
| OIDC `sub=repo:org/*` assumes any repo in the org | happy | covered | `./smokes/security/oidc-smoke.sh` |
| OIDC feature ref / other org / wrong aud / bad signature denied | sad/authz | covered | `./smokes/security/oidc-smoke.sh` |
| `iam:PassRole` when `iam:PassedToService=events.amazonaws.com` | happy | covered | `./smokes/security/oidc-smoke.sh` |
| `iam:PassRole` to Step Functions denied by `PassedToService` | sad/authz | covered | `./smokes/security/oidc-smoke.sh` |
| `iam:GetRole` only when `aws:ResourceTag/env=prod` | sad/authz | covered | `./smokes/security/oidc-smoke.sh` |
| `kms:ViaService` / service-origin `aws:SourceArn` | sad/authz | missing | [#223](https://github.com/kgz/awsl/issues/223) |
| Access key → account (`AWSBOX_ACCOUNT_IDS`) | happy | covered | `./smokes/security/multi-account-smoke.sh` · [multi-account.md](multi-account.md) |
| S3 bucket and IAM role in A hidden from B | sad/authz | covered | `./smokes/security/multi-account-smoke.sh` |
| `sts:AssumeRole` role in B trusts `arn:aws:iam::<A>:root` + `sts:ExternalId`; user in A assumes | happy | covered | `./smokes/security/multi-account-smoke.sh` |
| AssumeRole without ExternalId / from account C / user missing `sts:AssumeRole` | sad/authz | covered | `./smokes/security/multi-account-smoke.sh` |
| Trust `StringEquals` `aws:PrincipalOrgID` does not allow | sad/authz | covered | `./smokes/security/multi-account-smoke.sh` |
| Cross-account resource policy Allow | sad/authz | missing | [#233](https://github.com/kgz/awsl/issues/233) |
| Real AWS: deny-user + empty role simulate PutObject | sad/authz | covered | `./smokes/parity/aws-parity-iam-denied.sh` (~$0; default creds) · [docs/aws-parity-agent-iam.md](aws-parity-agent-iam.md) |
| Lambda invoke hello (basic role) | happy | covered | `./smokes/lambda/lambda-smoke.sh` |
| Lambda deploy zip | happy | covered | `./smokes/lambda/lambda-deploy-smoke.sh` |
| **Lambda role missing `s3:PutObject` → AccessDenied** | sad/authz | covered | `./smokes/lambda/lambda-authz-smoke.sh` |
| Lambda role trust `aws:SourceAccount` = function account → CreateFunction ok; other account → refused; plain trust ok | happy + sad/authz | covered | `./smokes/lambda/lambda-trust-condition-smoke.sh` |
| Lambda role trust `aws:SourceArn` = function ARN → CreateFunction ok; other ARN → refused | happy + sad/authz | covered | `./smokes/lambda/lambda-trust-sourcearn-smoke.sh` |
| REST API import from OpenAPI + `aws_proxy` public route | happy | covered | `./smokes/apigw/apigw-rest-smoke.sh` · [apigw-rest.md](apigw-rest.md) |
| REST REQUEST authorizer Allow → handler gets context | happy | covered | `./smokes/apigw/apigw-rest-smoke.sh` |
| REST authorizer, no token → 401 | sad/authz | covered | `./smokes/apigw/apigw-rest-smoke.sh` |
| REST authorizer Deny → 403 | sad/authz | covered | `./smokes/apigw/apigw-rest-smoke.sh` |
| REST unknown route → 403 | sad/other | covered | `./smokes/apigw/apigw-rest-smoke.sh` |
| REST custom domain + base-path mapping | happy | covered | `./smokes/apigw/apigw-rest-smoke.sh` |
| REST request via custom domain (root mapping, local DNS) | happy | covered | `./smokes/apigw/apigw-rest-smoke.sh` |
| REST request via custom domain named base path | happy | covered | `./smokes/apigw/apigw-rest-smoke.sh` |
| REST custom domain unmapped prefix → 403 Forbidden | sad/other | covered | `./smokes/apigw/apigw-rest-smoke.sh` |
| REST `x-api-key` valid key (minted by Lambda: CreateApiKey + CreateUsagePlanKey + GetUsagePlans) → 200 | happy | covered | `./smokes/apigw/apigw-usage-plan-smoke.sh` · [apigw-rest.md](apigw-rest.md#api-keys-and-usage-plans) |
| REST `apiKeySource` AUTHORIZER (`usageIdentifierKey`) | happy | covered | `./smokes/apigw/apigw-usage-plan-smoke.sh` |
| REST `apiKeyRequired` with no key / unknown key / disabled key → 403 | sad/authz | covered | `./smokes/apigw/apigw-usage-plan-smoke.sh` |
| REST revoked key (DeleteApiKey) → 403 | sad/authz | covered | `./smokes/apigw/apigw-usage-plan-smoke.sh` |
| REST usage plan throttle (rate/burst) → 429 | sad/other | covered | `./smokes/apigw/apigw-usage-plan-smoke.sh` |
| REST usage plan quota → 429 | sad/other | covered | `./smokes/apigw/apigw-usage-plan-smoke.sh` |
| `apigateway:POST` on `/apikeys` denied for a role (CreateApiKey) | sad/authz | covered | `./smokes/apigw/apigw-usage-plan-smoke.sh` · [#311](https://github.com/kgz/awsl/issues/311) |
| REST usage plan `get-usage` / per-stage throttle | happy | missing | [#309](https://github.com/kgz/awsl/issues/309) |
| REST `HTTP_PROXY` forwards curl `-d` form-urlencoded body bytes unchanged to the backend | happy | covered | `./smokes/apigw/apigw-proxy-body-smoke.sh` · [apigw-rest.md](apigw-rest.md) · [#364](https://github.com/kgz/awsl/issues/364) |
| REST `HTTP_PROXY` via VPC link to internal NLB to ECS task, path param + injected header at backend | happy | covered | `./smokes/apigw/apigw-nlb-ecs-smoke.sh` phase A · [apigw-rest.md](apigw-rest.md) |
| REST VPC_LINK to NLB with stopped/unhealthy target → 5xx | sad | covered | `./smokes/apigw/apigw-nlb-ecs-smoke.sh` phase A |
| ECS awsvpc `describe-tasks` privateIPv4Address inside subnet CIDR and equals container VPC IP; that address reachable on the VPC | happy | covered | `./smokes/apigw/apigw-nlb-ecs-smoke.sh` · [#268](https://github.com/kgz/awsl/issues/268) |
| REST `HTTP_PROXY` straight to an ECS awsvpc task, path param + injected service token reach backend | happy | covered | `./smokes/apigw/apigw-nlb-ecs-smoke.sh` |
| REST no token / Deny authorizer: backend receives nothing | sad/authz | covered | `./smokes/apigw/apigw-nlb-ecs-smoke.sh` |
| REST backend task stopped → API 5xx (AWS 504/503, emulator 500) | sad/other | covered | `./smokes/apigw/apigw-nlb-ecs-smoke.sh` |
| VPC Lambda → host service by mapped hostname | happy | covered | `./smokes/lambda/lambda-vpc-smoke.sh` · [lambda-vpc.md](lambda-vpc.md) |
| VPC Lambda → unmapped hostname → ENOTFOUND | sad/other | covered | `./smokes/lambda/lambda-vpc-smoke.sh` |
| Non-VPC Lambda blocked from mapped private hosts | sad/other | covered | `./smokes/lambda/lambda-vpc-smoke.sh` · [#187](https://github.com/kgz/awsl/issues/187) |
| Lambda reads per-stage secret → OAuth client-credentials token → POST to external HTTP API | happy | covered | `./smokes/lambda/lambda-secret-oauth-smoke.sh` |
| Lambda stage isolation (stage=b uses b's secret) and env-var base URL drives the call | happy | covered | `./smokes/lambda/lambda-secret-oauth-smoke.sh` |
| Lambda role missing `secretsmanager:GetSecretValue` → fails, external API sees no request | sad/authz | covered | `./smokes/lambda/lambda-secret-oauth-smoke.sh` |
| Lambda OAuth wrong client secret → 401, document not posted | sad/other | covered | `./smokes/lambda/lambda-secret-oauth-smoke.sh` |
| Lambda role missing other actions | sad/authz | missing | extend `lambda-authz-smoke.sh` / [#150](https://github.com/kgz/awsl/issues/150) |
| ECS run-task + HTTP reachable | happy | covered | `./smokes/compute/ecs-smoke.sh` |
| ECS `delete-cluster` → INACTIVE omitted from `list-clusters`; describe still returns it | happy | covered | `./smokes/compute/ecs-inactive-cluster-smoke.sh` · [#401](https://github.com/kgz/stackwrangler/issues/401) |
| **ECS task role missing `s3:PutObject` → AccessDenied** | sad/authz | covered | `./smokes/compute/ecs-authz-smoke.sh` |
| ECS secrets `valueFrom` (ASM JSON key + SSM) via execution role | happy | covered | `./smokes/compute/ecs-taskdef-smoke.sh` |
| **ECS execution role deny GetSecretValue → ResourceInitializationError** | sad/authz | covered | `./smokes/compute/ecs-taskdef-smoke.sh` |
| ECS `networkMode: host` + portMappings listens on host | happy | covered | `./smokes/compute/ecs-taskdef-smoke.sh` |
| ECS `networkMode: host` task role: creds on host 127.0.0.1 (`AWS_CONTAINER_CREDENTIALS_FULL_URI`), endpoint on loopback, no DNAT | happy | covered | `./smokes/compute/ecs-host-creds-smoke.sh` |
| ECS host task without a role gets no credentials env; another task id → 404 | sad/authz | covered | `./smokes/compute/ecs-host-creds-smoke.sh` |
| ECS container create failure → STOPPED + stoppedReason | sad/other | covered | `./smokes/compute/ecs-taskdef-smoke.sh` |
| ECR create-repository + `get-login-password` + docker push/pull `127.0.0.1:5000/<repo>` | happy | covered | `./smokes/compute/ecr-smoke.sh` |
| ECS task image `<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>` with `ecr:BatchGetImage` | happy | covered | `./smokes/compute/ecr-smoke.sh` |
| **ECS execution role without `ecr:BatchGetImage` → task STOPPED** | sad/authz | covered | `./smokes/compute/ecr-smoke.sh` |
| `docker push` of the ECR repositoryUri hostname | happy | missing | [#218](https://github.com/kgz/awsl/issues/218) |
| Lambda `PackageType=Image` ECR pull authz | sad/authz | missing | [#219](https://github.com/kgz/awsl/issues/219) |
| ECS in-container SDK via 169.254 creds URI | sad/authz | thin | [#154](https://github.com/kgz/awsl/issues/154) |
| Public hosted zone + UPSERT A / A-alias / CNAME; `list-resource-record-sets` | happy | covered | `./smokes/networking/route53-smoke.sh` · [r53.md](r53.md) |
| Public zone names resolve via `dig @127.0.0.1` inside LocalEmu | happy | covered | `./smokes/networking/route53-smoke.sh` |
| Profile `local` `route53 list-hosted-zones` includes the public zone | happy | covered | `./smokes/networking/route53-smoke.sh` |
| Private zone create still works alongside public | happy | covered | `./smokes/networking/route53-smoke.sh` |
| **`route53:ListHostedZones` explicit deny** (public smoke) | sad/authz | covered | `./smokes/networking/route53-smoke.sh` |
| Private zone CNAME → internal NLB resolves and connects from ECS in the associated VPC | happy | covered | `./smokes/networking/r53-private-smoke.sh` · [r53-private.md](r53-private.md) |
| Private zone alias to ALB returns the ALB addresses | happy | covered | `./smokes/networking/r53-private-smoke.sh` |
| Private zone A and AAAA from the associated VPC | happy | covered | `./smokes/networking/r53-private-smoke.sh` |
| EC2 in the associated VPC resolves the private zone | happy | covered | `./smokes/networking/r53-private-smoke.sh` |
| Private names from an unassociated VPC | sad/other | covered | `./smokes/networking/r53-private-smoke.sh` |
| **`route53:ListHostedZones` explicit deny** | sad/authz | covered | `./smokes/networking/r53-private-smoke.sh` |
| Lambda `VpcConfig` private DNS | happy | missing | [#245](https://github.com/kgz/awsl/issues/245) |
| ECS EC2 bridge service behind an internal NLB (2 tasks) | happy | covered | `./smokes/compute/ecs-ec2-smoke.sh` |
| ECS task killed → replaced and re-registered in the target group | happy | covered | `./smokes/compute/ecs-ec2-smoke.sh` |
| ECS container instance from an ASG + launch template | happy | covered | `./smokes/compute/ecs-ec2-smoke.sh` |
| ASG create + set-desired-capacity 2 + describe shows 2 instances | happy | covered | `./smokes/compute/autoscaling-smoke.sh` · [batch-stubs.md](batch-stubs.md) |
| Application Auto Scaling register/describe DynamoDB RCU target | happy | covered | `./smokes/compute/application-autoscaling-smoke.sh` |
| Batch compute environment + job queue create/describe | happy | covered | `./smokes/compute/batch-smoke.sh` |
| Elastic Beanstalk create/describe application | happy | covered | `./smokes/compute/elasticbeanstalk-smoke.sh` |
| App Runner list-services / list-connections (empty stub) | happy | covered | `./smokes/compute/apprunner-smoke.sh` |
| Batch / Beanstalk / App Runner / ASG authz deny | sad/authz | missing | [#334](https://github.com/kgz/awsl/issues/334) |
| App Runner CreateService + traffic | happy | missing | [#335](https://github.com/kgz/awsl/issues/335) |
| Batch SubmitJob dataplane | happy | missing | [#335](https://github.com/kgz/awsl/issues/335) |
| Elastic Beanstalk environment provision | happy | missing | [#335](https://github.com/kgz/awsl/issues/335) |
| ECS `CODE_DEPLOY` service starts blue tasks behind the listener | happy | covered | `./smokes/compute/ecs-ec2-smoke.sh` |
| ECS CodeDeploy blue/green: v2 on green, listener swap, blue stopped | happy | covered | `./smokes/compute/ecs-ec2-smoke.sh`, `./smokes/compute/codedeploy-smoke.sh` |
| ECS CodeDeploy revision names a missing task definition → Failed | sad/other | covered | `./smokes/compute/ecs-ec2-smoke.sh`, `./smokes/compute/codedeploy-smoke.sh` |
| CodeDeploy Lambda app + canary deployment config + create-deployment Succeeded | happy | covered (control plane) | `./smokes/compute/codedeploy-smoke.sh` |
| CodeDeploy Lambda canary alias weight shift | happy | missing | [#340](https://github.com/kgz/awsl/issues/340) |
| CodeDeploy deny create-deployment / create-application | sad/authz | missing | [#341](https://github.com/kgz/awsl/issues/341) |
| **ECS deny `ecs:CreateService` → AccessDenied** | sad/authz | covered | `./smokes/compute/ecs-ec2-smoke.sh` |
| EC2 running + user-data file | happy | covered | `./smokes/compute/ec2-smoke.sh` |
| EC2 IMDSv2 instance-profile reads secret | happy | covered | `./smokes/compute/ec2-imds-smoke.sh` |
| EC2 instance-profile missing GetSecretValue → AccessDenied | sad/authz | covered | `./smokes/compute/ec2-imds-smoke.sh` |
| SSM SendCommand AWS-RunShellScript returns stdout | happy | covered | `./smokes/compute/ec2-imds-smoke.sh` |
| SSM SendCommand without ssm:SendCommand → AccessDenied | sad/authz | covered | `./smokes/compute/ec2-imds-smoke.sh` |
| Private subnet with no `0.0.0.0/0` cannot reach a public host | sad/other | covered | `./smokes/networking/vpc-routing-smoke.sh` · [vpc-routing.md](vpc-routing.md) |
| Private subnet reaches a public host via an HTTP proxy over peering | happy | covered | `./smokes/networking/vpc-routing-smoke.sh` |
| VPC peering both ways; deleting one route breaks that direction | sad/other | covered | `./smokes/networking/vpc-routing-smoke.sh` · Lambda: `./smokes/networking/vpc-egress-smoke.sh` |
| NAT gateway `0.0.0.0/0` restores egress | happy | covered | `./smokes/networking/vpc-routing-smoke.sh` |
| VPC Lambda private subnet: public host blocked; S3 only via GW endpoint; peer OK; IGW restores; routes replay after restart | happy + sad/other | covered | `./smokes/networking/vpc-egress-smoke.sh` · [vpc-routing.md](vpc-routing.md) · slice `examples/serverless-v3-rest/slices/egress/` |
| Attach/DetachInternetGateway keeps the same `localemu-vpc-*` Docker network id | happy | covered | `./smokes/networking/vpc-egress-smoke.sh` · [#386](https://github.com/kgz/awsl/issues/386) |
| ECS `bridge` task joins subnet VPC (`localemu-vpc-*`) and keeps default bridge | happy | covered | `./bin/vpc-egress-bridge-check.sh` (from `vpc-egress-smoke.sh`) · [#230](https://github.com/kgz/awsl/issues/230) |
| Private ECS task reaches a public host only through an egress proxy (`HTTP_PROXY`) | happy | covered | `./smokes/networking/egress-proxy-smoke.sh` |
| Same task with proxy env unset cannot reach the public host directly | sad/other | covered | `./smokes/networking/egress-proxy-smoke.sh` |
| Egress proxy allowlist refuses another host (task sees 403) | sad/authz | covered | `./smokes/networking/egress-proxy-smoke.sh` |
| Private ECS task reaches the emulator endpoint without the proxy (`NO_PROXY`) | happy | covered | `./smokes/networking/egress-proxy-smoke.sh` |
| Private ECS task reaches the emulator endpoint without the proxy (`NO_PROXY`) | happy | covered (currently fails) | `./smokes/networking/egress-proxy-smoke.sh` |
| Non-root image in private subnet (no default route) cannot reach a public host | sad/other | covered | `./smokes/networking/egress-proxy-smoke.sh` · [#270](https://github.com/kgz/awsl/issues/270) |
| ECS `awsvpc` task is not on the default docker bridge (`ip route` / networks) | sad/other | covered | `./smokes/networking/egress-proxy-smoke.sh` · [#271](https://github.com/kgz/awsl/issues/271) |
| Private ECS task reaches the emulator endpoint without the proxy (`NO_PROXY`) | happy | covered (currently fails) | `./smokes/networking/egress-proxy-smoke.sh` · [#269](https://github.com/kgz/awsl/issues/269) |
| Interface VPCE `PrivateDnsEnabled`: service hostname resolves in-VPC and call reaches awsbox (ecr/logs/ssm/sts/ecs) | happy | covered | `./smokes/networking/vpce-private-dns-smoke.sh` · [vpce-private-dns.md](vpce-private-dns.md) |
| Same service hostname from another VPC does not resolve to that endpoint IP | sad/other | covered | `./smokes/networking/vpce-private-dns-smoke.sh` |
| Gateway endpoint prefix-list route | sad/other | covered | `./smokes/networking/vpc-egress-smoke.sh` · [#230](https://github.com/kgz/awsl/issues/230) |
| SG allows TCP only from SG A: EC2 and ECS in A connect, B refused | happy | covered | `./smokes/networking/sg-enforcement-smoke.sh` · [sg-enforcement.md](sg-enforcement.md) |
| SG rule revoke/authorize updates a running target | sad/other | covered | `./smokes/networking/sg-enforcement-smoke.sh` |
| Prefix list and CIDR allow one address and refuse another | happy | covered | `./smokes/networking/sg-enforcement-smoke.sh` |
| RDS on a subnet allows 5432 only from SG A | happy | covered | `./smokes/networking/sg-enforcement-smoke.sh` |
| NLB path sees client IP at the target SG | happy | missing | [#236](https://github.com/kgz/awsl/issues/236) |
| VPC Lambda traffic filtered by its security groups | sad/other | covered | `./smokes/networking/sg-enforcement-smoke.sh` · [sg-enforcement.md](sg-enforcement.md) · [#237](https://github.com/kgz/awsl/issues/237) |
| Console label for a VPC ID and an NLB ARN glob | happy | covered | `./smokes/account/labels-smoke.sh` · [labels.md](labels.md) |
| `GET /_awsl/labels` | happy | covered | `./smokes/account/labels-smoke.sh` |
| Labels file missing → empty `GET /_awsl/labels` and no console label | sad/other | covered | `./smokes/account/labels-smoke.sh` |
| Two awsvpc ECS tasks on one host: direct ENI works | happy | covered | `./smokes/networking/ecs-hairpin-smoke.sh` · [ecs-hairpin.md](ecs-hairpin.md) · [#181](https://github.com/kgz/awsl/issues/181) |
| Same-host peer→NLB VIP fails under host DNAT (AWS-like hairpin) | sad/other | covered | `./smokes/networking/ecs-hairpin-smoke.sh` · [ecs-hairpin.md](ecs-hairpin.md) · [#181](https://github.com/kgz/awsl/issues/181) |
| NLB TCP :443 → two instance targets | happy | covered | `./smokes/networking/elbv2-smoke.sh` · [elbv2.md](elbv2.md) |
| Internal NLB :10080 → two target ports; closed on the edge address | happy | covered | `./smokes/networking/elbv2-smoke.sh` |
| NLB target sees the client source IP | happy | covered | `./smokes/networking/elbv2-smoke.sh` |
| NLB TLS listener forwards after termination | happy | covered | `./smokes/networking/elbv2-smoke.sh` |
| ALB host + path → TG-A, other requests → default TG | happy | covered | `./smokes/networking/elbv2-smoke.sh` |
| LB DNS from a VPC instance and from the host | happy | covered | `./smokes/networking/elbv2-smoke.sh` |
| Unhealthy NLB target receives no new connections | sad/other | covered | `./smokes/networking/elbv2-smoke.sh` |
| **ELBv2 deny-user CreateLoadBalancer → AccessDenied** | sad/authz | covered | `./smokes/networking/elbv2-smoke.sh` |
| ELBv2 console list / target health | ui | missing | [#241](https://github.com/kgz/awsl/issues/241) |
| ELBv2 TLS listener presents its ACM certificate | happy | missing | [#242](https://github.com/kgz/awsl/issues/242) |
| ACM request DNS-validated cert + describe/list | happy | covered | `./smokes/security/acm-smoke.sh` · [acm.md](acm.md) |
| ACM import-certificate | happy | covered | `./smokes/security/acm-smoke.sh` |
| ACM ARN on API GW custom domain | happy | covered | `./smokes/security/acm-smoke.sh` |
| ACM ARN stored on ALB HTTPS listener | happy | covered | `./smokes/security/acm-smoke.sh` |
| **ACM deny-user RequestCertificate → AccessDenied** | sad/authz | covered | `./smokes/security/acm-smoke.sh` |
| ACM console | ui | missing | [#333](https://github.com/kgz/awsl/issues/333) |
| ELBv2 HTTP health check treats 500 as unhealthy | sad/other | missing | [#243](https://github.com/kgz/awsl/issues/243) |
| WAFv2 create WebACL + associate API GW stage; get/list association | happy | covered | `./smokes/networking/waf-smoke.sh` · [waf.md](waf.md) |
| Network Firewall create rule group + firewall policy; describe/list | happy | covered | `./smokes/networking/network-firewall-fms-smoke.sh` · [network-firewall.md](network-firewall.md) |
| Firewall Manager put/get/list policy stub | happy | covered | `./smokes/networking/network-firewall-fms-smoke.sh` · [network-firewall.md](network-firewall.md) |
| Network Firewall packet filtering | happy | missing | [#441](https://github.com/kgz/stackwrangler/issues/441) · [network-firewall.md](network-firewall.md) |
| Firewall Manager org policy enforcement | happy | missing | [#442](https://github.com/kgz/stackwrangler/issues/442) · [network-firewall.md](network-firewall.md) |
| **WAFv2 deny-user CreateWebACL → AccessDenied** | sad/authz | covered | `./smokes/networking/waf-authz-smoke.sh` |
| WAFv2 rule evaluation blocks/allows HTTP | happy | missing | [#326](https://github.com/kgz/awsl/issues/326) · [waf.md](waf.md) |
| WAFv2 console | ui | missing | [#324](https://github.com/kgz/awsl/issues/324) |
| CFN `AWS::WAFv2::WebACL` / Association deploy | happy | missing | [#325](https://github.com/kgz/awsl/issues/325) |
| CFN/CDK/SAM deploy S3+Lambda write | happy | covered | `./smokes/iac/cfn-smoke.sh`, `./smokes/iac/cdk-smoke.sh`, `./smokes/iac/sam-smoke.sh` |
| Serverless v3 deploy → `/public/health` → redeploy → remove | happy | covered | `./smokes/iac/serverless-v3-smoke.sh` · [serverless-stackwrangler.md](serverless-stackwrangler.md) |
| Serverless v3 `${ssm:…}` + RestApi OpenAPI `Body` resource | happy | covered | `./smokes/iac/serverless-v3-smoke.sh` |
| Serverless v4 topic+consumer deploy (≥2 MiB zip / Expect: 100-continue) → SNS publish → SQS ESM Lambda → redeploy → remove; `.serverless/` owned by invoking user | happy | covered | `./smokes/iac/serverless-v4-smoke.sh` · [serverless-stackwrangler.md](serverless-stackwrangler.md) · [#467](https://github.com/kgz/awsl/issues/467) · [#469](https://github.com/kgz/awsl/issues/469) |
| Serverless v4 `${ssm:…}` + cross-stack `Fn::ImportValue` SNS→SQS | happy | covered | `./smokes/iac/serverless-v4-smoke.sh` |
| Serverless v4 sad: missing auth; host aws without `AWS_ENDPOINT_URL` refuses real AWS; TLS-down; missing `Fn::ImportValue` deploy fails; SNS filter-drop absent from S3 | sad/other | covered | `./smokes/iac/serverless-v4-smoke.sh` · [#460](https://github.com/kgz/awsl/issues/460) |
| Serverless v4 yarn workspace: `--cwd packages/service` mounts workspace root, sibling import bundles | happy | covered | `./smokes/iac/serverless-v4-workspace-smoke.sh` · [#468](https://github.com/kgz/awsl/issues/468) |
| aws-redirect DNS: AWS suffixes (A + dualstack AAAA) resolve only to the proxy — no public A/AAAA | happy | covered | `./smokes/iac/serverless-v4-smoke.sh` · [serverless-awsbox.md](serverless-awsbox.md) · [#464](https://github.com/kgz/awsl/issues/464) |
| aws-redirect TLS edge down → connection error (not real AWS auth) | sad/other | covered | `./smokes/iac/serverless-v4-smoke.sh` · [serverless-awsbox.md](serverless-awsbox.md) · [#464](https://github.com/kgz/awsl/issues/464) |
| Serverless v3 http-event REQUEST authorizer | happy | missing | [#328](https://github.com/kgz/awsl/issues/328) |
| Serverless v3 smoke deliberate failure | sad/other | missing | [#330](https://github.com/kgz/awsl/issues/330) |
| CFN failed create → `ROLLBACK_COMPLETE`, created resources removed, delete + recreate | sad/other | covered | `./smokes/iac/cfn-lifecycle-smoke.sh` |
| CFN delete-stack removes resources; `DeletionPolicy: Retain` kept | happy | covered | `./smokes/iac/cfn-lifecycle-smoke.sh` |
| CFN failed update → `UPDATE_ROLLBACK_COMPLETE` (not `UPDATE_COMPLETE`) | sad/other | covered | `./smokes/iac/cfn-lifecycle-smoke.sh` |
| CFN part-created stack delete skips never-created GetAtt deps → `DELETE_COMPLETE`, redeploy | sad/other | covered | `./smokes/iac/cfn-lifecycle-smoke.sh` (#470) |
| CFN failed update reverts in-place resource changes | sad/other | missing | [#228](https://github.com/kgz/awsl/issues/228) |
| CFN `DeletionPolicy: Snapshot` | sad/other | missing | [#228](https://github.com/kgz/awsl/issues/228) |
| Real AWS CFN S3+Lambda (same template) | happy | covered | `./smokes/parity/aws-parity-cfn-s3-lambda.sh` · [aws-parity-cfn.md](aws-parity-cfn.md) |
| Real AWS CFN empty Lambda role → AccessDenied | sad/authz | covered | `./smokes/parity/aws-parity-cfn-authz.sh` |
| Real AWS HF cheap: DDB GSI/condition, schedule→Lambda, REST Deny 403, API key/usage plan, S3 GW VPCE | happy+sad | covered | `./smokes/parity/aws-parity-hf-cheap.sh` (~$0–cents; ask before real) · [aws-parity-hf-cheap.md](aws-parity-hf-cheap.md) |
| Real AWS HF skipped: WAF, R53 zone, ACM without DNS, Transfer, CodeDeploy target stack, Batch/ASG compute | — | skipped (cost) | [aws-parity-hf-cheap.md](aws-parity-hf-cheap.md) skipped gaps |
| Prowler aws scan (isolated, scoped unused-services) | happy | covered | `./smokes/security/prowler-smoke.sh` · [prowler.md](prowler.md) |
| Prowler failing-API count ≤ baseline (ratchet) | sad/other | covered | `./smokes/security/prowler-smoke.sh` |
| S3 Control GetPublicAccessBlock / ListAccessPoints (account) | happy | covered | `./smokes/security/prowler-smoke.sh` spot-check |
| SQS send/receive/delete | happy | covered | `./smokes/messaging/sqs-smoke.sh` |
| SQS MessageRetentionPeriod > 14d → InvalidAttributeValue | sad/other | covered | `./smokes/messaging/sqs-smoke.sh` |
| **SQS deny-user SendMessage → AccessDenied** | sad/authz | covered | `./smokes/messaging/sqs-authz-smoke.sh` |
| Lambda SendMessage using CreateQueue / !Ref QueueUrl (`sqs.<region>.localhost`) | happy | covered | `./smokes/lambda/sqs-lambda-queueurl-smoke.sh` · [lambda-vpc.md](lambda-vpc.md) · [#459](https://github.com/kgz/awsl/issues/459) |
| ECS SendMessage using CreateQueue QueueUrl (`sqs.<region>.localhost`, bridge task) | happy | covered | `./smokes/compute/ecs-sqs-queueurl-smoke.sh` · [lambda-vpc.md](lambda-vpc.md) · [#463](https://github.com/kgz/awsl/issues/463) |
| SQS → Lambda event source mapping invokes Lambda, message deleted | happy | covered | `./smokes/lambda/sqs-lambda-dlq-smoke.sh` |
| SQS redrive (maxReceiveCount 2) to DLQ on Lambda failure | happy | covered | `./smokes/lambda/sqs-lambda-dlq-smoke.sh` |
| Lambda role without SQS read perms → CreateEventSourceMapping refused | sad/authz | covered | `./smokes/lambda/sqs-lambda-dlq-smoke.sh` |
| SQS VisibilityTimeout < function timeout → CreateEventSourceMapping refused | sad/other | covered | `./smokes/lambda/sqs-lambda-dlq-smoke.sh` |
| ESM MaximumConcurrency < 2 → CreateEventSourceMapping refused | sad/other | covered | `./smokes/lambda/sqs-lambda-dlq-smoke.sh` |
| Lambda role loses SQS poll perms after ESM create → polling stops / LastProcessingResult or State | sad/authz | covered | `./smokes/lambda/sqs-lambda-dlq-smoke.sh` |
| Lambda role re-granted SQS poll perms → ESM resumes, message consumed, LastProcessingResult cleared | happy | covered | `./smokes/lambda/sqs-lambda-dlq-smoke.sh` |
| SQS → Lambda ReportBatchItemFailures: 1 of 3 fails → 2 deleted, 1 redelivered → DLQ | happy | covered | `./smokes/lambda/sqs-lambda-batch-failures-smoke.sh` |
| SQS → Lambda empty batchItemFailures deletes whole batch | happy | covered | `./smokes/lambda/sqs-lambda-batch-failures-smoke.sh` |
| SQS → Lambda unknown itemIdentifier fails whole batch → DLQ | sad/other | covered | `./smokes/lambda/sqs-lambda-batch-failures-smoke.sh` |
| SQS → Lambda without ReportBatchItemFailures ignores response body | sad/other | covered | `./smokes/lambda/sqs-lambda-batch-failures-smoke.sh` |
| SQS → Lambda ESM disable stops polling; re-enable drains backlog; retention expiry drops | happy | covered | `./smokes/lambda/sqs-lambda-esm-enable-smoke.sh` |
| SQS → Lambda ESM keeps delivering past STS session expiry (short `AWSBOX_STS_ASSUME_ROLE_DURATION`) | happy | covered | `./smokes/lambda/sqs-lambda-esm-cred-refresh-smoke.sh` |
| SQS → Lambda ESM role deleted after create → `LastProcessingResult` PROBLEM (not stuck `None`) | sad/other | covered | `./smokes/lambda/sqs-lambda-esm-cred-refresh-smoke.sh` |
| Lambda `PutFunctionConcurrency` reserved=1 → second concurrent sync invoke `TooManyRequestsException` (429) | sad/other | covered | `./smokes/lambda/lambda-reserved-concurrency-smoke.sh` |
| Lambda reserved concurrency 0 → every sync invoke throttled (429) | sad/other | covered | `./smokes/lambda/lambda-reserved-concurrency-smoke.sh` |
| SQS ESM in-flight ≤ reserved concurrency; throttled msgs return to queue (not DLQ before maxReceiveCount) | happy | covered | `./smokes/lambda/lambda-reserved-concurrency-smoke.sh` |
| ESM `ScalingConfig.MaximumConcurrency` vs reserved concurrency (lower wins) | sad/other | covered | `./smokes/lambda/lambda-reserved-concurrency-smoke.sh` |
| ESM `ScalingConfig.MaximumConcurrency` alone (reserved unset) → in-flight ≤ MaximumConcurrency | happy | covered | `./smokes/lambda/lambda-reserved-concurrency-smoke.sh` |
| SNS create/publish | happy | covered | `./smokes/messaging/sns-smoke.sh` |
| SNS deny Publish | sad/authz | covered | `./smokes/messaging/sns-authz-smoke.sh` |
| SNS MaximumMessageSize CreateTopic/Set; default >256 KiB reject; 300 KiB–1 MiB publish + SQS raw | happy/sad | covered | `./smokes/messaging/sns-max-message-size-smoke.sh` |
| SNS large-topic (>256 KiB) subscribe: http/email/sms/application → InvalidParameter; sqs/lambda/firehose ok; Set refused with http sub | sad/happy | covered | `./smokes/messaging/sns-max-message-size-smoke.sh` |
| SNS → SQS fan-out (envelope, raw delivery, filter policy) | happy | covered | `./smokes/messaging/sns-sqs-fanout-smoke.sh` |
| SNS FilterPolicy limits (empty/`>5` keys/`>150` combinations; both scopes; 150-value happy) | happy+sad | covered | `./smokes/messaging/sns-filter-policy-limits-smoke.sh` |
| SNS → SQS queue policy not allowing topic / missing policy → not delivered; unsubscribe stops delivery | sad/authz | covered | `./smokes/messaging/sns-sqs-fanout-smoke.sh` |
| SNS → SQS with `KmsMasterKeyId=alias/aws/sqs` → not delivered | sad | covered | `./smokes/messaging/sns-sqs-fanout-smoke.sh` |
| SNS → SQS queue CMK without `sns.amazonaws.com` `kms:GenerateDataKey` + `kms:Decrypt` → not delivered | sad/authz | covered | `./smokes/messaging/sns-sqs-fanout-smoke.sh` |
| SNS → SQS queue CMK whose key policy Allows `sns.amazonaws.com` those actions → delivered | happy | covered | `./smokes/messaging/sns-sqs-fanout-smoke.sh` |
| EventBridge put-events + rule | happy | covered | `./smokes/messaging/events-smoke.sh` |
| EventBridge deny PutEvents | sad/authz | covered | `./smokes/messaging/events-authz-smoke.sh` |
| EventBridge `rate(1 minute)` rule invokes Lambda target (CFN `Events::Rule`) | happy | covered | `./smokes/messaging/events-schedule-smoke.sh` |
| EventBridge `disable-rule` stops scheduled invocations | happy | covered | `./smokes/messaging/events-schedule-smoke.sh` |
| EventBridge rule → Lambda without `lambda:InvokeFunction` (`events.amazonaws.com`) → no invocation | sad/authz | covered | `./smokes/messaging/events-schedule-smoke.sh` |
| EventBridge `cron(* * * * ? *)` rule invokes Lambda target (other cron/rate forms: [#317](https://github.com/kgz/awsl/issues/317)) | happy | covered | `./smokes/messaging/events-schedule-smoke.sh` |
| DynamoDB put/get | happy | covered | `./smokes/data/dynamodb-smoke.sh` |
| DynamoDB deny PutItem | sad/authz | covered | `./smokes/data/dynamodb-authz-smoke.sh` |
| DynamoDB table with GSI + TTL deployed via CloudFormation (serverless slice) | happy | covered | `./smokes/data/dynamodb-depth-smoke.sh` |
| DynamoDB GSI query, table query, scan with filter | happy | covered | `./smokes/data/dynamodb-depth-smoke.sh` |
| DynamoDB UpdateItem expression (`SET`, `if_not_exists`, `REMOVE`) | happy | covered | `./smokes/data/dynamodb-depth-smoke.sh` |
| DynamoDB TransactWriteItems commit | happy | covered | `./smokes/data/dynamodb-depth-smoke.sh` |
| DynamoDB TTL expiry removes item from table and GSI | happy | covered | `./smokes/data/dynamodb-depth-smoke.sh` (sweep via `DELETE /_aws/dynamodb/expired`, LocalEmu-only) |
| DynamoDB duplicate conditional put / failed update condition → `ConditionalCheckFailedException` | sad/other | covered | `./smokes/data/dynamodb-depth-smoke.sh` |
| DynamoDB cancelled transaction → `TransactionCanceledException`, no partial write | sad/other | covered | `./smokes/data/dynamodb-depth-smoke.sh` |
| DynamoDB Allow on index ARN only / table ARN only / Deny on index ARN | sad/authz | covered | `./smokes/data/dynamodb-depth-smoke.sh` |
| DynamoDB Batch*/Transact* under table-scoped policy | sad/authz | missing | [#306](https://github.com/kgz/awsl/issues/306) |
| DynamoDB `aws:ResourceTag` on index ARN | sad/authz | missing | [#307](https://github.com/kgz/awsl/issues/307) |
| Step Functions Pass execution | happy | covered | `./smokes/messaging/sfn-smoke.sh` |
| Step Functions deny StartExecution | sad/authz | covered | `./smokes/messaging/sfn-authz-smoke.sh` |
| Step Functions console state machines list | happy | covered | console e2e `sfn-state-machines.spec.ts` · thin list (Create/detail → [#533](https://github.com/kgz/awsl/issues/533)) |
| Secrets create/get | happy | covered | `./smokes/security/secrets-smoke.sh` |
| Secrets deny GetSecretValue | sad/authz | covered | `./smokes/security/secrets-authz-smoke.sh` |
| Secret resource policy explicit deny beats Lambda-role IAM Allow (`GetSecretValue`, `DescribeSecret`) | sad/authz | covered | `./smokes/security/resource-policy-smoke.sh` |
| KMS encrypt/decrypt | happy | covered | `./smokes/security/kms-smoke.sh` |
| KMS deny Decrypt | sad/authz | covered | `./smokes/security/kms-authz-smoke.sh` |
| KMS console Customer managed keys list | ui | covered | `console/e2e/kms-keys.spec.ts` |
| KMS key policy delegates to IAM and role Encrypt/Decrypt/GenerateDataKey succeeds | happy | covered | `./smokes/security/resource-policy-smoke.sh` |
| KMS key policy without IAM delegation denies a role IAM allows | sad/authz | covered | `./smokes/security/resource-policy-smoke.sh` |
| KMS key policy explicit deny Encrypt | sad/authz | covered | `./smokes/security/resource-policy-smoke.sh` |
| S3 bucket policy explicit deny GetObject/ListBucket | sad/authz | covered | `./smokes/security/resource-policy-smoke.sh` |
| Secrets Manager CMK GetSecretValue follows key policy | sad/authz | covered | `./smokes/security/resource-policy-smoke.sh` |
| Secrets Manager CreateSecret/PutSecretValue with a CMK follows key policy | sad/authz | covered | `./smokes/security/resource-policy-smoke.sh` |
| SSM SecureString GetParameter/PutParameter follows CMK key policy | sad/authz | covered | `./smokes/security/resource-policy-smoke.sh` |
| Cross-account resource policy (identity and resource must both allow) | sad/authz | missing | [#233](https://github.com/kgz/awsl/issues/233) · needs [#213](https://github.com/kgz/awsl/issues/213) |
| Kinesis console Data streams list | happy | covered | console e2e `kinesis-streams.spec.ts` · thin list (Create/detail → [#539](https://github.com/kgz/awsl/issues/539)) |
| Kinesis put/get | happy | covered | `./smokes/messaging/kinesis-smoke.sh` |
| Kinesis deny PutRecord | sad/authz | covered | `./smokes/messaging/kinesis-authz-smoke.sh` |
| Logs deny PutLogEvents | sad/authz | covered | `./smokes/logs/logs-authz-smoke.sh` |
| API GW deny CreateApi | sad/authz | covered | `./smokes/apigw/apigw-authz-smoke.sh` |
| EC2 deny RunInstances | sad/authz | covered | `./smokes/compute/ec2-authz-smoke.sh` |
| CFN console list/detail tabs | ui | covered | `console/e2e/cfn-stacks.spec.ts` |
| Built-service list chrome matches OD mocks, disabled controls explained | ui | covered | `console/e2e/services-chrome.spec.ts` |
| Transfer / RDS / ECS / VPC / load balancer detail pages (tabs, sections, disabled controls) | ui | covered | `console/e2e/services-detail.spec.ts` |
| CFN Create stack (upload/paste) in console | ui | covered | `console/e2e/cfn-create-stack.spec.ts` · [#93](https://github.com/kgz/awsl/issues/93) |
| CFN Update / change sets / StackSets in console | ui | missing | [#94](https://github.com/kgz/awsl/issues/94)–[#95](https://github.com/kgz/awsl/issues/95) |
| Transfer create-server / create-user API | happy | covered | `./smokes/transfer/transfer-smoke.sh` |
| SFTP SSH-key put → LocalEmu S3 (+ ObjectCreated Lambda) | happy | covered | `./smokes/transfer/transfer-key-smoke.sh` |
| SFTP key put → S3 (short dataplane) | happy | covered | `./smokes/transfer/transfer-dataplane-smoke.sh` |
| `stackwrangler up` while this checkout's beta `atmoz/sftp` container holds the emulator port | sad | covered | `./smokes/transfer/transfer-sftp-port-smoke.sh` |
| `stackwrangler up` while another project or process holds the SFTP host port | sad | covered | `./smokes/transfer/transfer-sftp-port-smoke.sh` |
| **Wrong SSH key rejected (no password fallback)** | sad/authz | covered | `./smokes/transfer/transfer-key-smoke.sh` |
| **Transfer empty role → simulate PutObject deny** | sad/authz | covered | `./smokes/transfer/transfer-authz-smoke.sh` |
| Transfer under-permissioned role (SFTP bytes) | sad/authz | missing | [#141](https://github.com/kgz/awsl/issues/141) |
| Transfer create/describe/update/delete-connector, test-connection | happy | covered | `./smokes/transfer/transfer-connector-smoke.sh` |
| Transfer start-file-transfer: S3 object → remote SFTP (Lambda-created tenant connector) | happy | covered | `./smokes/transfer/transfer-connector-smoke.sh` |
| Transfer connector events in CloudWatch Logs | happy | covered | `./smokes/transfer/transfer-connector-smoke.sh` |
| **Transfer connector access role without `s3:GetObject`** | sad/authz | covered | `./smokes/transfer/transfer-connector-smoke.sh` |
| **Transfer connector access role without secret read / `kms:Decrypt`** | sad/authz | covered | `./smokes/transfer/transfer-connector-smoke.sh` |
| **Transfer connector access role trust scoped to another account** | sad/authz | covered | `./smokes/transfer/transfer-connector-smoke.sh` |
| **Transfer create-connector without `iam:PassRole`** | sad/authz | covered | `./smokes/transfer/transfer-connector-smoke.sh` |
| Transfer connector wrong trusted host key | sad | covered | `./smokes/transfer/transfer-connector-smoke.sh` |
| Transfer connector retrieve / AS2 | happy | missing | [#314](https://github.com/kgz/awsl/issues/314) |
| Transfer under-permissioned role (SFTP bytes) | sad/authz | missing | [#322](https://github.com/kgz/awsl/issues/322) |
| RDS Postgres SQL round-trip | happy | covered | `./smokes/data/rds-smoke.sh` |
| **RDS wrong password → auth denied** | sad/authz | covered | `./smokes/data/rds-authz-smoke.sh` |
| RDS IAM DB auth | sad/authz | missing | [#145](https://github.com/kgz/awsl/issues/145) |
| RDS MySQL instance + managed secret | happy | covered | `./smokes/data/rds-mysql-smoke.sh` |
| **RDS MySQL wrong password → access denied** | sad/authz | covered | `./smokes/data/rds-mysql-smoke.sh` |
| Aurora MySQL writer SQL via `rds!` secret | happy | covered | `./smokes/data/rds-mysql-smoke.sh` |
| **Aurora MySQL reader rejects writes** | sad/other | covered | `./smokes/data/rds-mysql-smoke.sh` |
| Aurora MySQL failover | sad/other | missing | [#225](https://github.com/kgz/awsl/issues/225) |
| Logs create/put/get | happy | covered | `./smokes/logs/logs-smoke.sh` |
| API GW HTTP create/invoke | happy | covered | `./smokes/apigw/apigw-smoke.sh` |
| **Seaweed vs LocalEmu S3 are separate stores** | sad/other | covered | `./smokes/s3/s3-dual-endpoint-smoke.sh` · [s3-backends.md](s3-backends.md) |
| `awsl apply` synthetic VPC/subnet/SG ids + CIDRs | happy | covered | `./smokes/account/mirror-smoke.sh` · [mirror.md](mirror.md) |
| `awsl apply` fixture tags (Name, CDK subnet, Tier=private RT) + TF data sources | happy | covered | `./smokes/account/mirror-tags-smoke.sh` · [mirror.md](mirror.md) |
| `awsl mirror --out` inside the repo (not gitignored) | sad/other | covered | `./smokes/account/mirror-smoke.sh` |
| `awsl apply` non-local endpoint | sad/other | covered | `./smokes/account/mirror-smoke.sh` |
| Real-account `awsl mirror` read (Describe/List/Get only) | happy | missing | [#220](https://github.com/kgz/awsl/issues/220) |
| Create VPC/subnet/SG with `_custom_id_` + account id in OwnerId/STS/ARNs | happy | covered | `./smokes/account/custom-id-smoke.sh` · [custom-ids.md](custom-ids.md) |
| Create route table, IGW, peering, instance, LB/TG suffix, REST/HTTP API, hosted zone, ECS cluster ARN with `_custom_id_` | happy | covered | `./smokes/account/custom-id-smoke.sh` |
| `_custom_id_` value fails the id format check | sad/other | covered | `./smokes/account/custom-id-smoke.sh` |
| Terraform bootstrap state bucket + DynamoDB lock, then remote-state apply | happy | covered | `AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./smokes/iac/terraform-backend-smoke.sh` · [terraform-stackwrangler.md](terraform-stackwrangler.md) |
| Terraform second plan no-change with S3 backend on LocalEmu | happy | covered | `AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./smokes/iac/terraform-backend-smoke.sh` |
| Terraform backend smoke canary: real AWS STS succeeds → abort | sad/other | covered | `AWSBOX_TERRAFORM_BACKEND_SMOKE=1 ./smokes/iac/terraform-backend-smoke.sh` |

---

## How to run the suite (local)

```bash
./bin/stackwrangler up --force
./bin/e2e.sh                    # includes IAM deny + S3 parity + playwright subset
./smokes/lambda/lambda-smoke.sh           # happy
./smokes/lambda/lambda-authz-smoke.sh     # sad/authz
./smokes/security/multi-account-smoke.sh    # key→account, AssumeRole, hidden bucket
./smokes/transfer/transfer-key-smoke.sh
./smokes/transfer/transfer-dataplane-smoke.sh
./smokes/transfer/transfer-connector-smoke.sh
./smokes/data/rds-smoke.sh              # needs psql
./smokes/data/rds-mysql-smoke.sh        # needs mysql
# …add others as you touch a surface
```

Wire new paths here **in the same PR** as the smoke. If deferred → Debt ticket + link in the Status column.
| Real AWS batch10 messaging/data/crypto | happy+sad | covered | `./smokes/parity/aws-parity-batch10.sh` |
