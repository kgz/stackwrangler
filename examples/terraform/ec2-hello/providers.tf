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

variable "name_prefix" {
  type    = string
  default = "awsbox-ec2"
}

provider "aws" {
  region                      = "us-east-1"
  access_key                  = var.awsbox_access_key
  secret_key                  = var.awsbox_secret_key
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    ec2 = var.awsbox_endpoint
    iam = var.awsbox_endpoint
    sts = var.awsbox_endpoint
  }
}
