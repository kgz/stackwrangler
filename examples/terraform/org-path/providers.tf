# Org-path S3 = LocalEmu STACKWRANGLER_IAM_ENDPOINT → :4566 (#162).
# Do not point this stack at SeaweedFS :8333.

variable "endpoint" {
  type        = string
  description = "LocalEmu IaC endpoint (STACKWRANGLER_IAM_ENDPOINT)"
  default     = "http://127.0.0.1:4566"
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
  description = "Prefix for resource names"
  default     = "sw-org"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR; unique /16 avoids Docker bridge collisions (#271)"
  default     = "10.91.0.0/16"
}

variable "sftp_user" {
  type    = string
  default = "sftpuser"
}

variable "create_rds" {
  type        = bool
  description = "Create Postgres (Docker engine). Set false if CreateDBInstance stalls (#718)."
  default     = true
}

variable "console_url" {
  type    = string
  default = "http://127.0.0.1:3000"
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
    ec2      = var.endpoint
    ecs      = var.endpoint
    iam      = var.endpoint
    lambda   = var.endpoint
    logs     = var.endpoint
    rds      = var.endpoint
    s3       = var.endpoint
    sts      = var.endpoint
    transfer = var.endpoint
  }
}
