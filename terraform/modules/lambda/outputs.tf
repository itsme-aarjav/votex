output "lambda_arn" {
  description = "ARN of the synthetic health check Lambda function"
  value       = var.enabled ? aws_lambda_function.health_check[0].arn : null
}

output "lambda_name" {
  description = "Name of the synthetic health check Lambda function"
  value       = var.enabled ? aws_lambda_function.health_check[0].function_name : null
}

output "alarm_arn" {
  description = "ARN of the synthetic health check CloudWatch alarm"
  value       = var.enabled ? aws_cloudwatch_metric_alarm.health_alarm[0].arn : null
}

