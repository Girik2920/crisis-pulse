terraform {
  required_version = ">= 1.4"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_dynamodb_table" "events" {
  name         = "${var.project_name}-events"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"
  range_key    = "timestamp"

  attribute {
    name = "event_id"
    type = "S"
  }

  attribute {
    name = "timestamp"
    type = "S"
  }

  attribute {
    name = "severity"
    type = "S"
  }

  global_secondary_index {
    name            = "severity-timestamp-index"
    hash_key        = "severity"
    range_key       = "timestamp"
    projection_type = "ALL"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  tags = var.tags
}

resource "aws_s3_bucket" "events_archive" {
  bucket = "${var.project_name}-events-archive-${data.aws_caller_identity.current.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "events_archive" {
  bucket = aws_s3_bucket.events_archive.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "events_archive" {
  bucket = aws_s3_bucket.events_archive.id

  rule {
    id     = "archive-old-events"
    status = "Enabled"

    filter {}

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }
}

resource "aws_kinesis_stream" "incident_stream" {
  name             = "${var.project_name}-incident-stream"
  shard_count      = 2
  retention_period = 24

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }

  tags = var.tags
}

resource "aws_sqs_queue" "incident_dlq" {
  name                      = "${var.project_name}-incident-dlq"
  message_retention_seconds = 1209600
  tags                      = var.tags
}

resource "aws_iam_role" "classifier_role" {
  name               = "${var.project_name}-classifier-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "classifier_policy" {
  name = "${var.project_name}-classifier-policy"
  role = aws_iam_role.classifier_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["kinesis:GetRecords", "kinesis:GetShardIterator", "kinesis:DescribeStream", "kinesis:ListStreams"]
        Resource = aws_kinesis_stream.incident_stream.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.events.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.events_archive.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["events:PutEvents"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "api_role" {
  name               = "${var.project_name}-api-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "api_policy" {
  name = "${var.project_name}-api-policy"
  role = aws_iam_role.api_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query", "dynamodb:Scan", "dynamodb:GetItem"]
        Resource = [aws_dynamodb_table.events.arn, "${aws_dynamodb_table.events.arn}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kinesis:PutRecord", "kinesis:PutRecords"]
        Resource = aws_kinesis_stream.incident_stream.arn
      }
    ]
  })
}

resource "aws_iam_role" "alert_role" {
  name               = "${var.project_name}-alert-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "alert_policy" {
  name = "${var.project_name}-alert-policy"
  role = aws_iam_role.alert_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

data "archive_file" "classifier_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/classifier"
  output_path = "${path.module}/.terraform/classifier.zip"
}

resource "aws_lambda_function" "classifier" {
  function_name    = "${var.project_name}-classifier"
  role             = aws_iam_role.classifier_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.classifier_zip.output_path
  source_code_hash = data.archive_file.classifier_zip.output_base64sha256
  timeout          = 300
  memory_size      = 512

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.events.name
      S3_BUCKET      = aws_s3_bucket.events_archive.bucket
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.crisis_pulse.name
      ENVIRONMENT    = var.environment
    }
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.incident_dlq.arn
  }

  tags = var.tags
}

resource "aws_lambda_event_source_mapping" "kinesis_trigger" {
  event_source_arn               = aws_kinesis_stream.incident_stream.arn
  function_name                  = aws_lambda_function.classifier.arn
  starting_position              = "TRIM_HORIZON"
  batch_size                     = 100
  bisect_batch_on_function_error = true
}

data "archive_file" "api_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/api_handler"
  output_path = "${path.module}/.terraform/api_handler.zip"
}

resource "aws_lambda_function" "api_handler" {
  function_name    = "${var.project_name}-api-handler"
  role             = aws_iam_role.api_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      DYNAMODB_TABLE = aws_dynamodb_table.events.name
      KINESIS_STREAM = aws_kinesis_stream.incident_stream.name
      ENVIRONMENT    = var.environment
    }
  }

  tags = var.tags
}

data "archive_file" "alert_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/alert_engine"
  output_path = "${path.module}/.terraform/alert_engine.zip"
}

resource "aws_lambda_function" "alert_engine" {
  function_name    = "${var.project_name}-alert-engine"
  role             = aws_iam_role.alert_role.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.11"
  filename         = data.archive_file.alert_zip.output_path
  source_code_hash = data.archive_file.alert_zip.output_base64sha256
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.alerts.arn
      ENVIRONMENT   = var.environment
    }
  }

  tags = var.tags
}

resource "aws_apigatewayv2_api" "crisis_api" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  description   = "Crisis Pulse public REST API"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
    max_age       = 300
  }

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "api_integration" {
  api_id             = aws_apigatewayv2_api.crisis_api.id
  integration_type   = "AWS_PROXY"
  integration_uri    = aws_lambda_function.api_handler.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "get_events" {
  api_id    = aws_apigatewayv2_api.crisis_api.id
  route_key = "GET /events"
  target    = "integrations/${aws_apigatewayv2_integration.api_integration.id}"
}

resource "aws_apigatewayv2_route" "post_ingest" {
  api_id    = aws_apigatewayv2_api.crisis_api.id
  route_key = "POST /ingest"
  target    = "integrations/${aws_apigatewayv2_integration.api_integration.id}"
}

resource "aws_cloudwatch_log_group" "api_logs" {
  name              = "/aws/apigateway/${var.project_name}"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.crisis_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }

  tags = var.tags
}

resource "aws_lambda_permission" "api_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.crisis_api.execution_arn}/*/*"
}

resource "aws_cloudwatch_event_bus" "crisis_pulse" {
  name = "${var.project_name}-bus"
  tags = var.tags
}

resource "aws_sns_topic" "alerts" {
  name = "${var.project_name}-alerts"
  tags = var.tags
}

resource "aws_cloudwatch_event_rule" "high_severity" {
  name           = "${var.project_name}-high-severity"
  event_bus_name = aws_cloudwatch_event_bus.crisis_pulse.name
  description    = "Trigger on high or critical severity events"

  event_pattern = jsonencode({
    source      = ["crisis-pulse.classifier"]
    detail-type = ["IncidentClassified"]
    detail = {
      severity = ["high", "critical"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "alert_lambda" {
  rule           = aws_cloudwatch_event_rule.high_severity.name
  event_bus_name = aws_cloudwatch_event_bus.crisis_pulse.name
  target_id      = "alert-engine"
  arn            = aws_lambda_function.alert_engine.arn
}

resource "aws_lambda_permission" "eventbridge_invoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.alert_engine.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.high_severity.arn
}

resource "aws_cloudwatch_log_group" "classifier_logs" {
  name              = "/aws/lambda/${var.project_name}-classifier"
  retention_in_days = 14
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "dlq_depth" {
  alarm_name          = "${var.project_name}-dlq-depth"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Messages in the dead-letter queue require investigation."
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    QueueName = aws_sqs_queue.incident_dlq.name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "${var.project_name}-classifier-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "Classifier Lambda error rate is elevated."
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    FunctionName = aws_lambda_function.classifier.function_name
  }

  tags = var.tags
}
