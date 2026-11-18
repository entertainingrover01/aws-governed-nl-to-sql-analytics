# The NL-to-SQL Lambda and its networking.
#
# The function runs inside the default VPC (so it can reach the private RDS
# instance) and reaches Bedrock, Secrets Manager, and DynamoDB through VPC
# endpoints — no NAT gateway, no public internet egress from the function.
#
# The psycopg2 layer zip (build/psycopg2-layer.zip) is built by
# scripts/build_layer.sh and must exist before `terraform apply`.
# scripts/deploy.sh runs the build first.

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src/lambda"
  output_path = "${path.module}/../build/lambda.zip"

  excludes = ["__pycache__"]
}

resource "aws_lambda_layer_version" "psycopg2" {
  layer_name          = "${local.name_prefix}-psycopg2"
  description         = "psycopg2-binary for the NL-to-SQL Lambda (built by scripts/build_layer.sh)."
  filename            = "${path.module}/../build/psycopg2-layer.zip"
  compatible_runtimes = ["python3.12"]
}

resource "aws_security_group" "lambda" {
  name        = "${local.name_prefix}-lambda"
  description = "NL-to-SQL Lambda: egress only."
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All egress (VPC endpoints and RDS)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "vpc_endpoints" {
  name        = "${local.name_prefix}-vpc-endpoints"
  description = "HTTPS from the Lambda to interface VPC endpoints."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTPS from the Lambda"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}

# Gateway endpoint for DynamoDB (no hourly charge).
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.default.ids
}

# Interface endpoints for Secrets Manager and Bedrock Runtime.
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = data.aws_subnets.default.ids
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name_prefix}-nl-to-sql"
  retention_in_days = 14
}

resource "aws_lambda_function" "nl_to_sql" {
  function_name = "${local.name_prefix}-nl-to-sql"
  description   = "Governed NL-to-SQL: Bedrock generates SQL, guardrails validate it, Postgres executes read-only, DynamoDB audits it."
  role          = aws_iam_role.lambda_exec.arn

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "nl_to_sql.handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256

  layers = [aws_lambda_layer_version.psycopg2.arn]

  environment {
    variables = {
      BEDROCK_MODEL_ID = var.bedrock_model_id
      AUDIT_TABLE      = aws_dynamodb_table.audit.name
      DB_SECRET_ARN    = aws_secretsmanager_secret.db_connection.arn
    }
  }

  vpc_config {
    subnet_ids         = data.aws_subnets.default.ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
}
