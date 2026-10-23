# Local state only. Run this workspace first so the app workspace has a
# bucket + lock table on LocalEmu before terraform init -backend-config.

resource "aws_s3_bucket" "state" {
  bucket = var.state_bucket
}

resource "aws_dynamodb_table" "lock" {
  name         = var.lock_table
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
