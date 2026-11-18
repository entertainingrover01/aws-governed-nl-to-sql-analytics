# Audit log

Every question sent to `POST /ask` produces exactly one DynamoDB item —
allowed, blocked, or errored. The audit write happens before the response is
returned, so there is no path through the API that skips logging. If the
audit write itself fails, the failure is logged to CloudWatch and the user
still gets their answer (a failed audit write never breaks a request).

## Table

- **Name:** `{project}-{environment}-audit` (e.g. `governed-nl-to-sql-dev-audit`)
- **Billing:** `PAY_PER_REQUEST`
- **Partition key:** `question_id` (String, UUID v4)
- **Global secondary index:** `by-timestamp` on `created_at` (String, ISO 8601 UTC)
- **Point-in-time recovery:** enabled

## Item schema

| Attribute | Type | Description |
|---|---|---|
| `question_id` | S | UUID v4, unique per request. Partition key. |
| `created_at` | S | ISO 8601 UTC timestamp of the request. GSI key. |
| `question` | S | The plain-English question, as submitted. |
| `generated_sql` | S | The SQL Bedrock generated. For `ALLOWED` items this is the executed SQL (with the enforced `LIMIT` applied); for `BLOCKED` items it is the SQL that was rejected. Empty when the model call failed. |
| `guardrail_verdict` | S | `ALLOWED`, `BLOCKED`, or `ERROR`. |
| `guardrail_reason` | S | Human-readable reason, e.g. `Allowed.` or `Unknown table(s): employees.` |
| `model_id` | S | Bedrock model id that generated the SQL. |
| `row_count` | N | Rows returned (`0` for blocked and errored requests). |
| `execution_ms` | N | Milliseconds from request receipt to verdict (allowed/blocked) or failure. |

## Sample items

Allowed:

```json
{
  "question_id": {"S": "7f3c2a10-9b1e-4c2d-8f4a-1e5d6a7b8c9d"},
  "created_at": {"S": "2026-11-18T18:40:12.123456+00:00"},
  "question": {"S": "What are the top 5 products by total sales revenue?"},
  "generated_sql": {"S": "SELECT p.product_name, SUM(s.total_amount) AS revenue FROM sales s JOIN products p ON s.product_id = p.product_id GROUP BY p.product_name ORDER BY revenue DESC LIMIT 5"},
  "guardrail_verdict": {"S": "ALLOWED"},
  "guardrail_reason": {"S": "Allowed."},
  "model_id": {"S": "anthropic.claude-sonnet-4-5-20250929-v1:0"},
  "row_count": {"N": "5"},
  "execution_ms": {"N": "1842"}
}
```

Blocked:

```json
{
  "question_id": {"S": "a1b2c3d4-0000-4000-8000-000000000000"},
  "created_at": {"S": "2026-11-18T18:41:03.987654+00:00"},
  "question": {"S": "Delete all sales from last year"},
  "generated_sql": {"S": "DELETE FROM sales WHERE sale_date < '2026-01-01'"},
  "guardrail_verdict": {"S": "BLOCKED"},
  "guardrail_reason": {"S": "Only SELECT (or WITH ... SELECT) queries are allowed."},
  "model_id": {"S": "anthropic.claude-sonnet-4-5-20250929-v1:0"},
  "row_count": {"N": "0"},
  "execution_ms": {"N": "1204"}
}
```

## Querying the log

List the most recent entries (the GSI is keyed on the timestamp, so a query
against it returns items in timestamp order):

```bash
TABLE=$(terraform -chdir=terraform output -raw audit_table_name)

aws dynamodb query \
  --table-name "$TABLE" \
  --index-name by-timestamp \
  --key-condition-expression "created_at > :t" \
  --expression-attribute-values '{":t": {"S": "2026-11-18T00:00:00+00:00"}}' \
  --scan-index-forward false \
  --limit 20
```

Find every blocked query:

```bash
aws dynamodb scan \
  --table-name "$TABLE" \
  --filter-expression "guardrail_verdict = :v" \
  --expression-attribute-values '{":v": {"S": "BLOCKED"}}' \
  --projection-expression "created_at, question, generated_sql, guardrail_reason"
```

## Retention

The table has no TTL: audit records are kept indefinitely by default.
Point-in-time recovery is enabled, so the log can be restored to any second
in the last 35 days. If retention limits are needed, add a TTL attribute in
`terraform/dynamodb.tf` — the application code needs no change.
