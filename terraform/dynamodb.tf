# Audit log: one item per question, including blocked and errored requests.
# PAY_PER_REQUEST keeps the demo cheap; point-in-time recovery protects the
# audit trail. See docs/audit-log.md for the item schema.
resource "aws_dynamodb_table" "audit" {
  name         = "${local.name_prefix}-audit"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "question_id"

  attribute {
    name = "question_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  # Query recent audit entries by timestamp, newest first.
  global_secondary_index {
    name            = "by-timestamp"
    hash_key        = "created_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }
}
