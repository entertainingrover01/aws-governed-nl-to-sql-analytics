output "api_url" {
  description = "Base URL of the HTTP API. POST questions to ${api_url}/ask."
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "widget_url" {
  description = "URL of the static demo widget hosted on S3."
  value       = "http://${aws_s3_bucket_website_configuration.widget.website_endpoint}"
}

output "frontend_bucket_name" {
  description = "S3 bucket the widget is uploaded to (used by scripts/deploy.sh)."
  value       = aws_s3_bucket.widget.id
}

output "audit_table_name" {
  description = "DynamoDB audit table name."
  value       = aws_dynamodb_table.audit.name
}

output "db_endpoint" {
  description = "RDS endpoint (hostname). Use with scripts/seed_db.sh."
  value       = aws_db_instance.retail.address
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the DB connection string."
  value       = aws_secretsmanager_secret.db_connection.arn
}

output "lambda_function_name" {
  description = "Name of the NL-to-SQL Lambda function."
  value       = aws_lambda_function.nl_to_sql.function_name
}
