# Secrets Manager secret holding the Postgres connection string.
#
# Terraform creates it with the RDS admin credentials so scripts/seed_db.sh
# can load the schema. After seeding, seed_db.sh updates this secret to the
# read-only analytics_ro connection string, so the Lambda only ever connects
# as the least-privilege user. The lifecycle block keeps Terraform from
# overwriting that switch on later applies.
#
# Using an existing Supabase Postgres instead of RDS: update this secret's
# value (AWS console or CLI) to {"connection_string": "postgres://..."} and
# the Lambda picks it up with no code change. See README.md.
resource "aws_secretsmanager_secret" "db_connection" {
  name        = "${local.name_prefix}/db-connection"
  description = "Postgres connection string for the NL-to-SQL Lambda (JSON: {connection_string})."
}

resource "aws_secretsmanager_secret_version" "db_connection" {
  secret_id = aws_secretsmanager_secret.db_connection.id

  secret_string = jsonencode({
    connection_string = "postgres://${var.db_username}:${urlencode(var.db_password)}@${aws_db_instance.retail.address}:${aws_db_instance.retail.port}/${var.db_name}"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
