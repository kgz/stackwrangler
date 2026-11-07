# vs SAM Local / serverless-offline

**AWS SAM Local** and **serverless-offline** run Lambda (and a limited API Gateway / HTTP surface) on your laptop. They are compute runners, not a full AWS-shaped account.

## Choose SAM Local / serverless-offline if

- You only need to invoke functions and hit a thin HTTP front door
- The rest of the stack lives in a shared AWS account or fixed fixtures
- Your templates are already SAM- or Serverless Framework-centric and that loop is enough

## Choose stackwrangler if

- OpenTofu / Terraform / CDK must create VPC, messaging, secrets, IAM, and compute together
- SNS / SQS / EventBridge / S3 events must actually move on one local account
- You need **authz that denies** and SG/VPC behaviour for the same deploy
- A mobile or other client talks to more than a single local Lambda URL

## Gap in one line

SAM Local / serverless-offline ≈ **Lambda (+ limited HTTP)**.  
stackwrangler ≈ **one local account** (emulator + patches + console + sidecars) that IaC and clients share.

Teams often combine SAM Local with real AWS for data stores. That works until you need local deny paths and cross-service wiring without a bill.

## Spine

Same Lambda-in-Docker idea where it matters — plus a full account with **IAM that denies** (not default-allow) across the services your OpenTofu stack actually creates.

Next: [Compare index](./) · [vs Moto](./vs-moto) · [Use case](../use-cases/opentofu-expo-iam)
