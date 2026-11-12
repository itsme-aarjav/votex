variable "aws_region" {
  description = "AWS region for Terraform state storage"
  type        = string
  default     = "eu-north-1"
}

variable "state_bucket_name" {
  description = "Globally unique name for the Terraform S3 remote state bucket"
  type        = string
}

variable "environment" {
  description = "Environment identifier"
  type        = string
  default     = "production"
}

