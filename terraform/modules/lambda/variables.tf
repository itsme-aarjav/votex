variable "enabled" {
  description = "Whether to provision the Lambda synthetic health check infrastructure (disabled by default until live HTTPS endpoints exist)"
  type        = bool
  default     = false
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "production"
}

variable "cluster_name" {
  description = "Associated EKS cluster name for naming and tags"
  type        = string
  default     = "votex-cluster"
}

variable "vote_health_url" {
  description = "External public HTTPS URL for Vote service health endpoint (e.g. https://<domain>/api/health)"
  type        = string
  default     = ""
}

variable "result_health_url" {
  description = "External public HTTPS URL for Result service health endpoint (e.g. https://<domain>/api/health)"
  type        = string
  default     = ""
}

variable "schedule_expression" {
  description = "EventBridge cron or rate expression for invocation schedule (default: every 5 minutes)"
  type        = string
  default     = "rate(5 minutes)"
}

variable "timeout" {
  description = "Lambda function execution timeout in seconds"
  type        = number
  default     = 15
}
