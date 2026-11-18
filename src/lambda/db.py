"""Postgres access for the NL-to-SQL Lambda.

The connection string is read from AWS Secrets Manager (never from code or
environment variables). The secret holds JSON with either:

  {"connection_string": "postgres://user:password@host:5432/retail"}

or the individual fields ``host``, ``port``, ``dbname``, ``username`` and
``password``, from which the connection string is built.

Every query runs in a read-only transaction (``SET TRANSACTION READ ONLY``)
with a statement timeout, as a second line of defence behind the guardrails
and the read-only ``analytics_ro`` database user.
"""

import json
import os

import boto3
import psycopg2
import psycopg2.extras

DEFAULT_STATEMENT_TIMEOUT_MS = 10_000

# Cached across warm invocations so the secret is fetched once per container.
_cached_connection_string = None


def _get_secret_string(secret_arn):
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=secret_arn)
    return response["SecretString"]


def get_connection_string(secret_arn=None):
    """Resolve the Postgres connection string from Secrets Manager."""
    global _cached_connection_string
    if _cached_connection_string is not None:
        return _cached_connection_string

    arn = secret_arn or os.environ["DB_SECRET_ARN"]
    raw = _get_secret_string(arn)
    try:
        secret = json.loads(raw)
    except (ValueError, TypeError):
        # The secret is a plain connection string, not JSON.
        _cached_connection_string = raw
        return _cached_connection_string

    if isinstance(secret, dict) and secret.get("connection_string"):
        _cached_connection_string = secret["connection_string"]
        return _cached_connection_string

    if isinstance(secret, dict):
        _cached_connection_string = (
            "postgres://{username}:{password}@{host}:{port}/{dbname}".format(
                username=secret["username"],
                password=secret["password"],
                host=secret["host"],
                port=secret.get("port", 5432),
                dbname=secret["dbname"],
            )
        )
        return _cached_connection_string

    raise ValueError("DB secret is neither a connection string nor a JSON object")


def get_connection(secret_arn=None):
    """Open a Postgres connection using the Secrets Manager credentials."""
    return psycopg2.connect(
        get_connection_string(secret_arn), connect_timeout=5
    )


def execute_readonly(sql, secret_arn=None, statement_timeout_ms=None):
    """Execute one validated SELECT in a read-only transaction.

    Returns ``{"columns": [...], "rows": [{...}, ...]}``. The caller is
    responsible for running the SQL through ``guardrails.validate_sql``
    first; this function adds the database-level guarantees (read-only
    transaction, statement timeout) regardless.
    """
    timeout = statement_timeout_ms or int(
        os.environ.get("STATEMENT_TIMEOUT_MS", DEFAULT_STATEMENT_TIMEOUT_MS)
    )
    conn = get_connection(secret_arn)
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SET TRANSACTION READ ONLY")
            cur.execute("SET statement_timeout = %s", (timeout,))
            cur.execute(sql)
            columns = [desc.name for desc in cur.description] if cur.description else []
            rows = [dict(row) for row in cur.fetchall()] if cur.description else []
        conn.rollback()  # end the read-only transaction; nothing to commit
        return {"columns": columns, "rows": rows}
    finally:
        conn.close()
