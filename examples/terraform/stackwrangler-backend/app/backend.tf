# Production-shaped backend (no LocalEmu bits). An *_override.tf file
# replaces this whole block — Terraform does not merge backend attributes.
# Copy backend_override.tf.example → backend_override.tf before init on awsbox.
terraform {
  backend "s3" {
    bucket         = "example-tf-state"
    key            = "stackwrangler-backend/app.tfstate"
    region         = "us-east-1"
    dynamodb_table = "example-tf-locks"
    encrypt        = true
  }
}
