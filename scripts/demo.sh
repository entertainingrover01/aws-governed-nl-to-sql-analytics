#!/usr/bin/env bash
# Demo the API with three questions: one valid, one blocked by the
# guardrails (a DELETE), and one referencing a table that does not exist.
#
# Usage:
#   ./scripts/demo.sh [API_URL]
# If API_URL is omitted, it is read from the terraform output.
#
# Note: the blocked cases depend on the model generating the disallowed SQL
# (a DELETE, or a query against a hallucinated table). The model usually
# does — the prompt asks for SQL and the questions are phrased to elicit it —
# but if it answers with a refusal instead, the guardrails never see a
# statement to block. The deterministic behavior of the guardrails is
# covered by tests/test_guardrails.py regardless of what the model does.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

API_URL="${1:-$(terraform -chdir="$ROOT/terraform" output -raw api_url)}"
API_URL="${API_URL%/}"

ask() {
  local label="$1" question="$2"
  echo "=== $label ==="
  echo "Q: $question"
  local body
  body="$(python3 -c "import json, sys; print(json.dumps({'question': sys.argv[1]}))" "$question")"
  if command -v jq >/dev/null; then
    curl -s -X POST "$API_URL/ask" -H "Content-Type: application/json" -d "$body" | jq .
  else
    curl -s -X POST "$API_URL/ask" -H "Content-Type: application/json" -d "$body"
    echo
  fi
  echo
}

ask "1. Valid question (expect ALLOWED + rows)" \
  "What are the top 5 products by total sales revenue?"

ask "2. Destructive request (expect BLOCKED)" \
  "Delete all sales from last year"

ask "3. Unknown table (expect BLOCKED)" \
  "How many employees work in each department?"
