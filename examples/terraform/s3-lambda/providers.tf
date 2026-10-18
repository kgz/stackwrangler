# All services on LocalEmu (:4566), including S3 — required for Lambda↔bucket.
# Console "General purpose buckets" still uses SeaweedFS; this example does not.

variable "awsbox_endpoint" {
  type    = string
  default = "http://127.0.0.1:4566"
}

variable "awsbox_access_key" {
  type    = string
  default = "awsbox"
}

variable "awsbox_secret_key" {
  type    = string
  default = "awsboxawsbox"
}

variable "bucket_name" {
  type        = string
  description = "S3 bucket name to create on LocalEmu"
  default     = "awsbox-iac-demo"
}

variable "function_name" {
  type    = string
  default = "awsbox-iac-writer"
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = var.awsbox_access_key
  secret_key                  = var.awsbox_secret_key
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3           = var.awsbox_endpoint
    iam          = var.awsbox_endpoint
    sts          = var.awsbox_endpoint
    lambda       = var.awsbox_endpoint
    logs         = var.awsbox_endpoint
    apigateway   = var.awsbox_endpoint
    apigatewayv2 = var.awsbox_endpoint
  }
}
