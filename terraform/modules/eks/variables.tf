variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.36"
}

variable "vpc_id" {
  description = "ID of the VPC where the cluster is deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for worker nodes"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for control plane communication"
  type        = list(string)
}

variable "node_instance_types" {
  description = "EC2 instance types for the worker nodes"
  type        = list(string)
  default     = ["m7i-flex.large"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 2
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of approved CIDR blocks permitted to communicate with the EKS public API endpoint"
  type        = list(string)
  default     = ["10.0.0.0/16"]
}
