# Terraform S3 Remote State Backend with Native S3 Lockfile Locking
# Compatible with Terraform >= 1.10.0
# Eliminates DynamoDB dependency using Amazon S3 native conditional writes (.tflock).
#
# Usage:
#   1. Ensure state bucket is provisioned via terraform/bootstrap.
#   2. Copy this file: cp backend.tf.example backend.tf
#   3. Initialize: terraform init -backend-config="bucket=<YOUR_STATE_BUCKET_NAME>" -migrate-state

terraform {
  backend "s3" {
    key          = "production/votex.tfstate"
    region       = "eu-north-1"
    encrypt      = true
    use_lockfile = true
  }
}

