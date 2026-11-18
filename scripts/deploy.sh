#!/usr/bin/env bash
# Deploy the full stack and publish the demo widget.
#
# Steps:
#   1. Build the psycopg2 Lambda layer (scripts/build_layer.sh).
#   2. terraform init + apply (provisions API, Lambda, DynamoDB, RDS,
#      Secrets Manager, S3).
#   3. Upload the frontend to S3 with the real API URL injected into
#      config.js.
#   4. Print the API URL and the widget URL.
#
# Prerequisites: terraform, aws CLI (authenticated), jq, psql not needed
# here. The DB password comes from TF_VAR_db_password or terraform.tfvars.
# After this script, run scripts/seed_db.sh to load the retail dataset.
#
# Usage: ./scripts/deploy.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for tool in terraform aws jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required but not installed" >&2; exit 1; }
done

echo "=== 1/3 Building the psycopg2 Lambda layer ==="
"$ROOT/scripts/build_layer.sh"

echo "=== 2/3 Applying Terraform ==="
terraform -chdir="$ROOT/terraform" init -input=false
terraform -chdir="$ROOT/terraform" apply -auto-approve

API_URL="$(terraform -chdir="$ROOT/terraform" output -raw api_url)"
BUCKET="$(terraform -chdir="$ROOT/terraform" output -raw frontend_bucket_name)"
WIDGET_URL="$(terraform -chdir="$ROOT/terraform" output -raw widget_url)"

echo "=== 3/3 Uploading the widget to s3://$BUCKET ==="
TMP_FRONTEND="$(mktemp -d)"
trap 'rm -rf "$TMP_FRONTEND"' EXIT
cp "$ROOT/frontend/index.html" "$ROOT/frontend/app.js" "$TMP_FRONTEND/"
sed "s|https://REPLACE_WITH_API_URL|$API_URL|" "$ROOT/frontend/config.js" > "$TMP_FRONTEND/config.js"
grep -q "REPLACE_WITH_API_URL" "$TMP_FRONTEND/config.js" && {
  echo "ERROR: API URL injection into config.js failed" >&2; exit 1;
}
aws s3 sync "$TMP_FRONTEND/" "s3://$BUCKET/" --delete

echo
echo "Deployed."
echo "  API URL:    $API_URL"
echo "  Widget URL: $WIDGET_URL"
echo
echo "Next: load the dataset with scripts/seed_db.sh, then open the widget URL."
