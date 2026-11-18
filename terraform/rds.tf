# RDS PostgreSQL holding the retail dataset.
#
# Single-AZ db.t3.micro, storage-encrypted, not publicly accessible: the
# Lambda reaches it privately inside the default VPC, and the security group
# allows Postgres traffic only from the Lambda's security group.
resource "aws_db_subnet_group" "retail" {
  name       = "${local.name_prefix}-retail"
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "Postgres access from the NL-to-SQL Lambda only."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Postgres from the Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
}

resource "aws_db_instance" "retail" {
  identifier     = "${local.name_prefix}-retail"
  engine         = "postgres"
  engine_version = "16.4"
  instance_class = "db.t3.micro"

  allocated_storage   = 20
  storage_type        = "gp3"
  storage_encrypted   = true
  multi_az            = false
  publicly_accessible = false

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.retail.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Demo settings: no final snapshot and no automated backups, so
  # `terraform destroy` cleans up fully. Enable backups for real use.
  backup_retention_period = 0
  skip_final_snapshot     = true
  delete_automated_backups = true
  deletion_protection     = false
}
