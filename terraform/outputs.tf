output "api_endpoint" {
  description = "Public API Gateway endpoint"
  value       = aws_apigatewayv2_api.crisis_api.api_endpoint
}

output "kinesis_stream_name" {
  description = "Kinesis stream name for incident ingestion"
  value       = aws_kinesis_stream.incident_stream.name
}

output "dynamodb_table_name" {
  description = "DynamoDB events table name"
  value       = aws_dynamodb_table.events.name
}

output "s3_archive_bucket" {
  description = "S3 bucket for event archiving"
  value       = aws_s3_bucket.events_archive.bucket
}

output "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  value       = aws_sns_topic.alerts.arn
}

output "dlq_url" {
  description = "Dead-letter queue URL"
  value       = aws_sqs_queue.incident_dlq.url
}
