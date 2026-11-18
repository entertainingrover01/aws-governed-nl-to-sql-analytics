#!/usr/bin/env bash
# Load the retail schema + seed data into Postgres and switch the Lambda to
# the read-only database user.
#
# Required environment variables:
#   PGUSER       Admin DB user (the Terraform db_username, e.g. nl_sql_admin)
#   PGPASSWORD   Admin DB password (the Terraform db_password)
#   RO_PASSWORD  Password to set for the read-only analytics_ro user
#
# Optional (defaults shown):
#   PGHOST       RDS endpoint. Defaults to the terraform output db_endpoint.
#   PGPORT       5432
#   PGDATABASE   retail (the Terraform db_name)
#   DB_SECRET_ARN  Secrets Manager ARN to update. Defaults to the terraform
#                  output db_secret_arn. Set to "skip" to leave the secret
#                  untouched (the Lambda then keeps using the admin user).
#
# After loading the schema, the script updates the Secrets Manager secret to
# the analytics_ro connection string, so the Lambda only ever connects as
# the least-privilege read-only user. The Terraform secret has
# lifecycle ignore_changes on the value, so later applies will not revert it.
#
# Requires: psql, aws CLI (for the secret update), terraform (for defaults).
# The machine running this needs network access to the RDS instance. The
# instance is not publicly accessible, so run this from inside the VPC
# (e.g. EC2, CloudShell in the same VPC) or through a bastion/SSM tunnel.
# For a Supabase Postgres, set PGHOST/PGDATABASE directly and DB_SECRET_ARN=skip.
#
# Usage:
#   PGUSER=nl_sql_admin PGPASSWORD='...' RO_PASSWORD='...' ./scripts/seed_db.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

command -v psql >/dev/null || { echo "psql is required but not installed" >&2; exit 1; }

: "${PGUSER:?PGUSER is required (admin DB user)}"
: "${PGPASSWORD:?PGPASSWORD is required (admin DB password)}"
: "${RO_PASSWORD:?RO_PASSWORD is required (password for the analytics_ro user)}"

PGPORT="${PGPORT:-5432}"
PGDATABASE="${PGDATABASE:-retail}"
if [ -z "${PGHOST:-}" ]; then
  PGHOST="$(terraform -chdir="$ROOT/terraform" output -raw db_endpoint)"
fi
DB_SECRET_ARN="${DB_SECRET_ARN:-$(terraform -chdir="$ROOT/terraform" output -raw db_secret_arn)}"

export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD

echo "Loading sql/retail_schema.sql into $PGDATABASE on $PGHOST ..."
psql -v ON_ERROR_STOP=1 -v ro_password="$RO_PASSWORD" -f "$ROOT/sql/retail_schema.sql"
echo "Schema + seed data loaded. Verifying row counts:"
psql -t -c "SELECT 'stores=' || COUNT(*) FROM stores; SELECT 'products=' || COUNT(*) FROM products; SELECT 'sales=' || COUNT(*) FROM sales;"

if [ "$DB_SECRET_ARN" != "skip" ]; then
  command -v aws >/dev/null || { echo "aws CLI is required to update the secret (or set DB_SECRET_ARN=skip)" >&2; exit 1; }
  echo "Switching the Secrets Manager secret to the read-only analytics_ro user ..."
  # URL-encode the password portion so special characters survive the URL.
  RO_CONN_ENCODED="$(python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$RO_PASSWORD")"
  RO_CONN="postgres://analytics_ro:${RO_CONN_ENCODED}@${PGHOST}:${PGPORT}/${PGDATABASE}"
  aws secretsmanager put-secret-value \
    --secret-id "$DB_SECRET_ARN" \
    --secret-string "{\"connection_string\": \"$RO_CONN\"}" \
    --query VersionId --output text
  echo "Secret updated. The Lambda now connects as analytics_ro (SELECT only)."
else
  echo "DB_SECRET_ARN=skip: secret left untouched; the Lambda still uses the admin credentials."
fi
