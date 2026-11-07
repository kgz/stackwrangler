# All control/data plane on LocalEmu (:4566), including S3 for Lambda↔bucket.
# Console General purpose buckets still use SeaweedFS (:8333) — see docs/s3-backends.md.

variable "endpoint" {
  type    = string
  default = "http://127.0.0.1:4566"
}

variable "access_key" {
  type    = string
  default = "stackwrangler"
}

variable "secret_key" {
  type    = string
  default = "stackwranglerstackwrangler"
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names (unique per apply recommended)"
  default     = "sw-v002"
}

variable "create_rds" {
  type        = bool
  description = "Create a Postgres DB instance (starts a Docker engine container)"
  default     = true
}

provider "aws" {
  region                      = var.region
  access_key                  = var.access_key
  secret_key                  = var.secret_key
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    apigateway     = var.endpoint
    dynamodb       = var.endpoint
    ec2            = var.endpoint
    ecs            = var.endpoint
    events         = var.endpoint
    iam            = var.endpoint
    kinesis        = var.endpoint
    kms            = var.endpoint
    lambda         = var.endpoint
    logs           = var.endpoint
    rds            = var.endpoint
    s3             = var.endpoint
    secretsmanager = var.endpoint
    sns            = var.endpoint
    sqs            = var.endpoint
    sfn            = var.endpoint
    sts            = var.endpoint
  }
}
