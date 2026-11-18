"""Lambda handler: governed NL-to-SQL analytics.

Request flow:
  1. Parse the plain-English question from the API Gateway event.
  2. Ask Amazon Bedrock (Converse API) to turn it into SQL, with the retail
     schema embedded in the prompt.
  3. Run the generated SQL through the deterministic guardrails
     (``guardrails.validate_sql``). Blocked queries are audited and
     rejected before touching the database.
  4. Execute allowed queries read-only against Postgres (``db.py``).
  5. Write an audit record to DynamoDB for every request — allowed,
     blocked, or errored — before returning the response.

Environment variables (set by Terraform):
  BEDROCK_MODEL_ID  Bedrock model id, e.g. anthropic.claude-sonnet-4-5-20250929-v1:0
  AUDIT_TABLE       DynamoDB audit table name
  DB_SECRET_ARN     Secrets Manager ARN holding the DB connection string
"""

import datetime
import json
import os
import re
import time
import uuid

import boto3

from db import execute_readonly
from guardrails import validate_sql
from schema import SCHEMA, render_schema_for_prompt

DEFAULT_MODEL_ID = "anthropic.claude-sonnet-4-5-20250929-v1:0"
MAX_QUESTION_CHARS = 1000
MAX_TOKENS = 1024

SYSTEM_PROMPT = """You convert plain-English questions into a single PostgreSQL \
SELECT query. Rules you must follow:
- Output ONLY the SQL query, with no explanation, no markdown, and no
  surrounding text. A single statement, no trailing semicolon.
- Use ONLY the tables and columns in the schema below. Never invent a table
  or column.
- The query must be read-only: SELECT or WITH ... SELECT only. Never
  generate INSERT, UPDATE, DELETE, DROP, ALTER, or any other statement.
- Never query information_schema or pg_catalog.
- Prefer explicit column lists over SELECT *. Aggregate with GROUP BY where
  the question asks for totals or rankings.
"""

_bedrock_client = None
_dynamodb_client = None


def _bedrock():
    global _bedrock_client
    if _bedrock_client is None:
        _bedrock_client = boto3.client("bedrock-runtime")
    return _bedrock_client


def _dynamodb():
    global _dynamodb_client
    if _dynamodb_client is None:
        _dynamodb_client = boto3.client("dynamodb")
    return _dynamodb_client


def extract_sql(text):
    """Pull the SQL statement out of a model response.

    The prompt asks for bare SQL, but models sometimes wrap it in a
    ```sql fenced block, so strip fences and surrounding whitespace.
    """
    if not text:
        return ""
    cleaned = text.strip()
    fence = re.search(r"```(?:sql)?\s*(.*?)\s*```", cleaned, re.DOTALL | re.IGNORECASE)
    if fence:
        cleaned = fence.group(1).strip()
    return cleaned


def generate_sql(question, model_id):
    """Ask Bedrock to translate the question into SQL."""
    user_text = (
        f"{render_schema_for_prompt()}\n\nQuestion: {question}\n\nSQL:"
    )
    response = _bedrock().converse(
        modelId=model_id,
        system=[{"text": SYSTEM_PROMPT}],
        messages=[{"role": "user", "content": [{"text": user_text}]}],
        inferenceConfig={"maxTokens": MAX_TOKENS, "temperature": 0},
    )
    parts = response["output"]["message"]["content"]
    text = "".join(part.get("text", "") for part in parts)
    return extract_sql(text)


def write_audit_record(record):
    """Write one audit item to DynamoDB. Audit failures are logged but never
    fail the request — the user still gets their answer."""
    table = os.environ.get("AUDIT_TABLE", "")
    if not table:
        print("AUDIT_TABLE not set; skipping audit write")
        return
    try:
        item = {
            "question_id": {"S": record["question_id"]},
            "created_at": {"S": record["created_at"]},
            "question": {"S": record["question"]},
            "generated_sql": {"S": record.get("generated_sql", "")},
            "guardrail_verdict": {"S": record["guardrail_verdict"]},
            "guardrail_reason": {"S": record.get("guardrail_reason", "")},
            "model_id": {"S": record.get("model_id", "")},
            "row_count": {"N": str(record.get("row_count", 0))},
            "execution_ms": {"N": str(record.get("execution_ms", 0))},
        }
        _dynamodb().put_item(TableName=table, Item=item)
    except Exception as exc:  # noqa: BLE001 - audit must never break the request
        print(f"Failed to write audit record: {exc}")


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, default=str),
    }


def handler(event, context):
    """API Gateway HTTP API (payload v2) handler for POST /ask."""
    started = time.monotonic()
    question_id = str(uuid.uuid4())
    created_at = datetime.datetime.now(datetime.timezone.utc).isoformat()
    model_id = os.environ.get("BEDROCK_MODEL_ID", DEFAULT_MODEL_ID)
    question = ""
    generated_sql = ""

    try:
        body = event.get("body") or "{}"
        if event.get("isBase64Encoded"):
            import base64

            body = base64.b64decode(body).decode("utf-8")
        payload = json.loads(body)
        question = str(payload.get("question", "")).strip()
    except (ValueError, TypeError):
        return _response(400, {"error": "Request body must be JSON with a 'question' field."})

    if not question:
        return _response(400, {"error": "Field 'question' is required."})
    if len(question) > MAX_QUESTION_CHARS:
        return _response(400, {"error": f"Question must be under {MAX_QUESTION_CHARS} characters."})

    try:
        generated_sql = generate_sql(question, model_id)
    except Exception as exc:  # noqa: BLE001 - surface Bedrock failures as a 502
        print(f"Bedrock call failed: {exc}")
        write_audit_record(
            {
                "question_id": question_id,
                "created_at": created_at,
                "question": question,
                "generated_sql": "",
                "guardrail_verdict": "ERROR",
                "guardrail_reason": "Bedrock model call failed.",
                "model_id": model_id,
                "execution_ms": int((time.monotonic() - started) * 1000),
            }
        )
        return _response(502, {"error": "The language model is unavailable. Try again later."})

    verdict = validate_sql(generated_sql, SCHEMA)
    execution_ms = int((time.monotonic() - started) * 1000)

    if not verdict.allowed:
        write_audit_record(
            {
                "question_id": question_id,
                "created_at": created_at,
                "question": question,
                "generated_sql": generated_sql,
                "guardrail_verdict": "BLOCKED",
                "guardrail_reason": verdict.reason,
                "model_id": model_id,
                "execution_ms": execution_ms,
            }
        )
        return _response(
            403,
            {
                "error": "Query blocked by guardrails.",
                "reason": verdict.reason,
                "generated_sql": generated_sql,
                "guardrail_verdict": "BLOCKED",
            },
        )

    try:
        result = execute_readonly(verdict.sql)
    except Exception as exc:  # noqa: BLE001 - surface DB failures as a 502
        print(f"Database execution failed: {exc}")
        write_audit_record(
            {
                "question_id": question_id,
                "created_at": created_at,
                "question": question,
                "generated_sql": generated_sql,
                "guardrail_verdict": "ERROR",
                "guardrail_reason": "Database execution failed.",
                "model_id": model_id,
                "execution_ms": int((time.monotonic() - started) * 1000),
            }
        )
        return _response(502, {"error": "The database query failed to execute."})

    execution_ms = int((time.monotonic() - started) * 1000)
    write_audit_record(
        {
            "question_id": question_id,
            "created_at": created_at,
            "question": question,
            "generated_sql": verdict.sql,
            "guardrail_verdict": "ALLOWED",
            "guardrail_reason": verdict.reason,
            "model_id": model_id,
            "row_count": len(result["rows"]),
            "execution_ms": execution_ms,
        }
    )
    return _response(
        200,
        {
            "question": question,
            "generated_sql": verdict.sql,
            "guardrail_verdict": "ALLOWED",
            "columns": result["columns"],
            "rows": result["rows"],
            "row_count": len(result["rows"]),
        },
    )
