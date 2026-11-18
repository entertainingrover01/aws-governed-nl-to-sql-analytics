# Least-privilege IAM for the NL-to-SQL Lambda.
#
# The function gets exactly four capabilities beyond basic execution:
#   - InvokeModel on the single configured Bedrock model.
#   - PutItem on the audit table only (no reads, no other tables).
#   - GetSecretValue on the single DB secret.
#   - VPC networking (managed policy) so it can reach RDS privately.

resource "aws_iam_role" "lambda_exec" {
  name = "${local.name_prefix}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_policy" "lambda_least_privilege" {
  name        = "${local.name_prefix}-lambda-least-privilege"
  description = "Bedrock InvokeModel (one model), DynamoDB PutItem (audit table), SecretsManager GetSecretValue (one secret)."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeBedrockModel"
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:${var.region}::foundation-model/${var.bedrock_model_id}"
      },
      {
        Sid      = "WriteAuditLog"
        Effect   = "Allow"
        Action   = "dynamodb:PutItem"
        Resource = aws_dynamodb_table.audit.arn
      },
      {
        Sid      = "ReadDbSecret"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.db_connection.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_least_privilege" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_least_privilege.arn
}
