variable "project" {
  description = "Project name, used as a prefix for all resources."
  type        = string
  default     = "governed-nl-to-sql"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "bedrock_model_id" {
  description = <<-EOT
    Bedrock model id used to translate questions into SQL. Must be a model
    with on-demand throughput enabled in the account (Bedrock console ->
    Model access). Change this variable to use a different model; the IAM
    policy in iam.tf scopes InvokeModel to exactly this model.
  EOT
  type        = string
  default     = "anthropic.claude-sonnet-4-5-20250929-v1:0"
}

variable "db_name" {
  description = "Name of the Postgres database created on the RDS instance."
  type        = string
  default     = "retail"
}

variable "db_username" {
  description = "Admin username for the RDS instance (used by seed_db.sh)."
  type        = string
  default     = "nl_sql_admin"
}

variable "db_password" {
  description = <<-EOT
    Admin password for the RDS instance. No default: pass it with
    TF_VAR_db_password or a terraform.tfvars file (gitignored). The Lambda
    does not use this password after seeding; seed_db.sh switches the
    Secrets Manager secret to the read-only analytics_ro user.
  EOT
  type        = string
  sensitive   = true
}
