output "state_bucket_name" {
  description = "Name of the provisioned S3 remote state bucket"
  value       = aws_s3_bucket.terraform_state.id
}

output "state_bucket_arn" {
  description = "ARN of the provisioned S3 remote state bucket"
  value       = aws_s3_bucket.terraform_state.arn
}

output "backend_init_command" {
  description = "Command to initialize main Terraform stack with this backend"
  value       = "terraform init -backend-config=\"bucket=${aws_s3_bucket.terraform_state.id}\""
}

