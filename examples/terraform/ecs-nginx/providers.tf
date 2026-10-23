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

variable "cluster_name" {
  type    = string
  default = "awsbox-ecs"
}

variable "family" {
  type    = string
  default = "awsbox-nginx"
}

variable "vpc_cidr" {
  type        = string
  default     = "10.42.0.0/16"
  description = "VPC CIDR; smokes pass a unique /16 to avoid Docker bridge collisions."
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = var.awsbox_access_key
  secret_key                  = var.awsbox_secret_key
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ecs = var.awsbox_endpoint
    ec2 = var.awsbox_endpoint
    iam = var.awsbox_endpoint
    sts = var.awsbox_endpoint
  }
}
