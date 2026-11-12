variable "aws_region" {
  description = "AWS Region to deploy the infrastructure"
  type        = string
  default     = "eu-north-1"
}

variable "environment" {
  description = "Environment name (single production environment)"
  type        = string
  default     = "production"
}

variable "cluster_name" {
  description = "Name of the EKS Cluster and infrastructure prefix"
  type        = string
  default     = "votex-cluster"
}

variable "cluster_version" {
  description = "Kubernetes control plane version"
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the Virtual Private Cloud"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (spanning 2 Availability Zones)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (spanning 2 Availability Zones)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "node_instance_types" {
  description = "Instance types for the EKS managed node group"
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

variable "enable_health_check_lambda" {
  description = "Enable external AWS Lambda synthetic health verifier"
  type        = bool
  default     = false
}

variable "vote_health_url" {
  description = "External public HTTPS URL for Vote service synthetic health check (configured upon live domain provisioning)"
  type        = string
  default     = ""
}

variable "result_health_url" {
  description = "External public HTTPS URL for Result service synthetic health check (configured upon live domain provisioning)"
  type        = string
  default     = ""
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of approved CIDR blocks permitted to communicate with the EKS public API endpoint (e.g. operator workstation public IP '/32'). Avoids unrestricted 0.0.0.0/0 exposure."
  type        = list(string)
  default     = ["10.0.0.0/16"]

  validation {
    condition     = length(var.cluster_endpoint_public_access_cidrs) > 0 && !contains(var.cluster_endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "The EKS public API endpoint must be restricted to approved operator CIDRs (e.g. ['<OPERATOR_IP>/32']). Unrestricted exposure ('0.0.0.0/0') is prohibited."
  }
}
