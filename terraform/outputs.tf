output "vpc_id" {
  description = "The ID of the created VPC"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "IDs of the private subnets hosting worker nodes"
  value       = module.vpc.private_subnet_ids
}

output "cluster_name" {
  description = "The Name of the Amazon EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint URL"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "kubeconfig_command" {
  description = "Run this command to configure local kubectl to interact with your new cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "health_check_lambda_arn" {
  description = "ARN of synthetic health check Lambda function"
  value       = module.lambda.lambda_arn
}

output "otel_collector_role_arn" {
  description = "IAM Role ARN for OpenTelemetry Collector IRSA"
  value       = module.eks.otel_collector_role_arn
}

output "ebs_csi_role_arn" {
  description = "IAM Role ARN for AWS EBS CSI Driver Controller IRSA"
  value       = module.eks.ebs_csi_role_arn
}
