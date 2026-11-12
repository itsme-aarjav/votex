output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane API server"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with cluster"
  value       = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
}

output "node_group_arn" {
  description = "Amazon Resource Name (ARN) of the EKS Node Group"
  value       = aws_eks_node_group.nodes.arn
}

output "cluster_iam_role_arn" {
  description = "ARN of the EKS Cluster IAM Role"
  value       = aws_iam_role.eks_cluster.arn
}

output "otel_collector_role_arn" {
  description = "IAM Role ARN for OpenTelemetry Collector IRSA"
  value       = aws_iam_role.otel_collector_irsa.arn
}

output "ebs_csi_role_arn" {
  description = "IAM Role ARN for AWS EBS CSI Driver Controller IRSA"
  value       = aws_iam_role.ebs_csi_irsa.arn
}

output "aws_lb_controller_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller IRSA"
  value       = aws_iam_role.aws_lb_controller_irsa.arn
}
