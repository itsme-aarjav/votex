# Archive Lambda source package
data "archive_file" "health_check_zip" {
  count       = var.enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.root}/../lambda/health_check/handler.py"
  output_path = "${path.module}/health_check_handler.zip"
}

# IAM Role for Lambda execution
resource "aws_iam_role" "lambda_exec" {
  count = var.enabled ? 1 : 0
  name  = "${var.cluster_name}-health-check-lambda-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "Votex"
  }
}

resource "aws_iam_role_policy" "lambda_policy" {
  count = var.enabled ? 1 : 0
  name  = "${var.cluster_name}-health-check-policy-${var.environment}"
  role  = aws_iam_role.lambda_exec[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
      }
    ]
  })
}

# Lambda Function
resource "aws_lambda_function" "health_check" {
  count            = var.enabled ? 1 : 0
  filename         = data.archive_file.health_check_zip[0].output_path
  source_code_hash = data.archive_file.health_check_zip[0].output_base64sha256
  function_name    = "${var.cluster_name}-synthetic-health-check"
  role             = aws_iam_role.lambda_exec[0].arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  timeout          = var.timeout

  environment {
    variables = {
      VOTE_HEALTH_URL   = var.vote_health_url
      RESULT_HEALTH_URL = var.result_health_url
      ENVIRONMENT       = var.environment
    }
  }

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "Votex"
  }
}

# EventBridge Schedule Rule (default every 5 min)
resource "aws_cloudwatch_event_rule" "schedule" {
  count               = var.enabled ? 1 : 0
  name                = "${var.cluster_name}-health-check-rule"
  description         = "Triggers Votex synthetic health check periodically"
  schedule_expression = var.schedule_expression

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "Votex"
  }
}

resource "aws_cloudwatch_event_target" "lambda_target" {
  count     = var.enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.schedule[0].name
  target_id = "VotexHealthCheckLambda"
  arn       = aws_lambda_function.health_check[0].arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  count         = var.enabled ? 1 : 0
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.health_check[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule[0].arn
}

# CloudWatch Alarm for Service Outages
resource "aws_cloudwatch_metric_alarm" "health_alarm" {
  count               = var.enabled ? 1 : 0
  alarm_name          = "${var.cluster_name}-synthetic-health-failure"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HealthCheckStatus"
  namespace           = "Votex/SyntheticMonitoring"
  period              = 300
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_description   = "Triggers when any Votex service synthetic health check reports DOWN or fails to emit"

  tags = {
    Environment = var.environment
    ManagedBy   = "Terraform"
    Project     = "Votex"
  }
}

