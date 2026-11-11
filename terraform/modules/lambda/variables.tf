variable "enabled" {
  description = "Whether to provision the Lambda synthetic health check infrastructure (opt-in disabled by default)"
  type        = bool
  default     = false
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Associated EKS cluster name for naming and tags"
  type        = string
  default     = "votex-cluster"
}

variable "vote_health_url" {
  description = "Target URL for the Vote service health endpoint"
  type        = string
  default     = "http://vote.votex.svc.cluster.local/api/health"
}

variable "result_health_url" {
  description = "Target URL for the Result service health endpoint"
  type        = string
  default     = "http://result.votex.svc.cluster.local/api/health"
}

variable "schedule_expression" {
  description = "EventBridge cron or rate expression for invocation schedule"
  type        = string
  default     = "rate(5 minutes)"
}

variable "timeout" {
  description = "Lambda function execution timeout in seconds"
  type        = number
  default     = 15
}

