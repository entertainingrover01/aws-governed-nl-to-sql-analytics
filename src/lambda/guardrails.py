"""Deterministic guardrails for LLM-generated SQL.

This module is the enforcement layer of the project. The Bedrock prompt
*asks* the model to generate safe, read-only SQL, but the prompt is not
trusted: every generated statement is validated here, with the standard
library only, before it is allowed anywhere near the database.

Rules (see docs/guardrails.md for the full write-up):
  1. The statement must be a single SELECT or WITH query.
  2. Mutating / administrative keywords are blocked outright.
  3. ``information_schema`` and ``pg_catalog`` are forbidden.
  4. Every table must exist in the allowlisted schema (or be a CTE defined
     in the query itself).
  5. Every column must exist in the allowlisted schema. For queries with
     a CTE, unqualified column checks are relaxed (CTE output columns are
     not in the schema) but qualified ``table.column`` references against
     real tables are still validated.
  6. A LIMIT is enforced: a missing LIMIT gets ``LIMIT 100`` appended, and
     a LIMIT above 100 is capped at 100.

``validate_sql`` returns a :class:`GuardrailResult` with the verdict, a
human-readable reason, and the (possibly rewritten) SQL to execute.
"""

import re
from dataclasses import dataclass

MAX_LIMIT = 100

# Whole-word keywords that are never allowed in a read-only analytics query.
BLOCKED_KEYWORDS = {
    "DROP",
    "DELETE",
    "UPDATE",
    "INSERT",
    "ALTER",
    "TRUNCATE",
    "GRANT",
    "REVOKE",
    "COPY",
    "CREATE",
    "INTO",  # blocks SELECT ... INTO (creates a table)
    "MERGE",
    "CALL",
    "DO",
    "VACUUM",
    "ANALYZE",
    "COMMENT",
    "SECURITY",
}

# System catalogs that must never be readable through the widget.
FORBIDDEN_SCHEMAS = {"information_schema", "pg_catalog"}

# SQL keywords and function names that are not column references. Used when
# collecting bare identifiers for the column allowlist check.
SQL_KEYWORDS = {
    "SELECT", "FROM", "WHERE", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER",
    "FULL", "CROSS", "ON", "AND", "OR", "NOT", "IN", "IS", "NULL", "AS",
    "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "ASC", "DESC",
    "DISTINCT", "ALL", "CASE", "WHEN", "THEN", "ELSE", "END", "UNION",
    "INTERSECT", "EXCEPT", "WITH", "RECURSIVE", "BETWEEN", "LIKE", "ILIKE",
    "EXISTS", "CAST", "TRUE", "FALSE", "NULLS", "FIRST",
    "LAST", "USING", "NATURAL", "OVER", "PARTITION", "INTERVAL",
    "YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND", "QUARTER",
    "WEEK", "DOW", "DOY", "EPOCH",
}

ALLOWED_FUNCTIONS = {
    "COUNT", "SUM", "AVG", "MIN", "MAX", "ROUND", "COALESCE", "NULLIF",
    "UPPER", "LOWER", "TRIM", "LENGTH", "ABS", "CEIL", "FLOOR",
    "DATE_TRUNC", "EXTRACT", "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP",
    "CURRENT_TIME", "LOCALTIME", "LOCALTIMESTAMP", "TO_CHAR",
    "CONCAT", "SUBSTRING", "REPLACE", "ROW_NUMBER", "RANK", "DENSE_RANK",
    "LAG", "LEAD",
}

# Matches -- line comments and /* block comments */.
_COMMENT_RE = re.compile(r"--[^\n]*|/\*.*?\*/", re.DOTALL)
# Matches single-quoted string literals, including '' escaped quotes.
_STRING_LITERAL_RE = re.compile(r"'(?:[^']|'')*'")
# Matches double-quoted identifiers ("column name").
_QUOTED_IDENT_RE = re.compile(r'"([^"]+)"')


@dataclass
class GuardrailResult:
    """Outcome of validating one generated statement."""

    allowed: bool
    reason: str
    sql: str = ""

    def __bool__(self):
        return self.allowed


def _strip_comments(sql):
    """Remove SQL comments so keywords cannot hide inside them."""
    return _COMMENT_RE.sub(" ", sql)


def _strip_string_literals(sql):
    """Replace string literals with '' so keywords inside data (e.g. a
    product named 'DROP') cannot trigger false positives."""
    return _STRING_LITERAL_RE.sub("''", sql)


def _scan_text(sql):
    """Text used for keyword/statement checks: comments and string literals
    removed, whitespace collapsed."""
    text = _strip_comments(sql)
    text = _strip_string_literals(text)
    return re.sub(r"\s+", " ", text).strip()


def _extract_cte_names(scan_text):
    """Return CTE names defined by a WITH clause, e.g. ``WITH top AS (...)``."""
    names = set()
    match = re.search(r"\bWITH\b\s+", scan_text, re.IGNORECASE)
    if not match:
        return names
    # CTE names appear as "<name> AS (" after WITH or after a comma.
    for cte_match in re.finditer(
        r"(?:\bWITH\b|,)\s*([A-Za-z_][A-Za-z0-9_]*)\s+AS\s*\(",
        scan_text,
        re.IGNORECASE,
    ):
        names.add(cte_match.group(1).lower())
    return names


def _extract_tables(scan_text):
    """Return the table names referenced after FROM and JOIN.

    Schema-qualified names (``public.sales``) are reduced to the bare table
    name; the schema part itself is checked separately against
    :data:`FORBIDDEN_SCHEMAS`.
    """
    tables = set()
    for match in re.finditer(
        r"\b(?:FROM|JOIN)\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)",
        scan_text,
        re.IGNORECASE,
    ):
        name = match.group(1)
        tables.add(name.split(".")[-1].lower())
    return tables


def _extract_aliases(scan_text):
    """Return aliases introduced with AS plus implicit SELECT-list aliases.

    Aliases are legitimate identifiers (e.g. ``ORDER BY revenue`` after
    ``SUM(total_amount) AS revenue``), so they are added to the set of
    identifiers the column check accepts.
    """
    aliases = set()
    for match in re.finditer(
        r"\bAS\s+([A-Za-z_][A-Za-z0-9_]*)", scan_text, re.IGNORECASE
    ):
        aliases.add(match.group(1).lower())
    return aliases


def _extract_qualified_columns(scan_text):
    """Return (table, column) pairs from ``table.column`` references."""
    pairs = set()
    for match in re.finditer(
        r"\b([A-Za-z_][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)",
        scan_text,
    ):
        pairs.add((match.group(1).lower(), match.group(2).lower()))
    return pairs


def _extract_bare_identifiers(scan_text):
    """Return bare word identifiers, minus keywords, functions, tables and
    aliases, for the column allowlist check."""
    words = set(w.lower() for w in re.findall(r"[A-Za-z_][A-Za-z0-9_]*", scan_text))
    words -= {k.lower() for k in SQL_KEYWORDS}
    words -= {f.lower() for f in ALLOWED_FUNCTIONS}
    return words


def _enforce_limit(sql):
    """Append ``LIMIT 100`` when the query has none; cap a larger LIMIT."""
    limit_match = re.search(r"\bLIMIT\s+(\d+)", sql, re.IGNORECASE)
    if limit_match is None:
        return sql.rstrip().rstrip(";") + f" LIMIT {MAX_LIMIT}"
    if int(limit_match.group(1)) > MAX_LIMIT:
        return re.sub(
            r"\bLIMIT\s+\d+",
            f"LIMIT {MAX_LIMIT}",
            sql,
            count=1,
            flags=re.IGNORECASE,
        )
    return sql


def validate_sql(sql, schema):
    """Validate one generated SQL statement against the allowlisted schema.

    ``schema`` is the ``SCHEMA`` dict from ``schema.py`` (table -> columns).
    """
    if sql is None or not str(sql).strip():
        return GuardrailResult(False, "Empty SQL statement.")

    cleaned = _strip_comments(str(sql)).strip()
    scan = _scan_text(cleaned)

    # Rule 1: single statement only. A trailing semicolon is fine; any
    # other semicolon means stacked statements.
    body = scan.rstrip(";").strip()
    if ";" in body:
        return GuardrailResult(
            False, "Multiple statements are not allowed (single SELECT only)."
        )

    # Rule 1: SELECT or WITH only.
    if not re.match(r"^(SELECT|WITH)\b", body, re.IGNORECASE):
        return GuardrailResult(
            False, "Only SELECT (or WITH ... SELECT) queries are allowed."
        )

    # Rule 2: blocked keywords (whole words, case-insensitive).
    words = set(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", scan.upper()))
    blocked = sorted(words & BLOCKED_KEYWORDS)
    if blocked:
        return GuardrailResult(
            False,
            "Blocked keyword(s): {}. Only read-only SELECT queries are allowed.".format(
                ", ".join(blocked)
            ),
        )

    # Rule 3: system catalogs are forbidden.
    lowered = scan.lower()
    for forbidden in FORBIDDEN_SCHEMAS:
        if forbidden in lowered:
            return GuardrailResult(
                False, f"Access to {forbidden} is not allowed."
            )

    # Rule 4: every table must be allowlisted (or a CTE defined in-query).
    cte_names = _extract_cte_names(scan)
    known_tables = {table.lower() for table in schema}
    tables = _extract_tables(scan)
    unknown_tables = sorted(t for t in tables if t not in known_tables and t not in cte_names)
    if unknown_tables:
        return GuardrailResult(
            False,
            "Unknown table(s): {}. Allowed tables: {}.".format(
                ", ".join(unknown_tables), ", ".join(sorted(known_tables))
            ),
        )
    if not tables:
        return GuardrailResult(False, "No table referenced in the query.")

    # Rule 5: every column must exist in the schema.
    # Qualified table.column references are always checked against the real
    # table (unless the qualifier is a CTE or a table alias).
    table_aliases = set()
    for match in re.finditer(
        r"\b(?:FROM|JOIN)\s+[A-Za-z_][A-Za-z0-9_]*(?:\s+(?:AS\s+)?([A-Za-z_][A-Za-z0-9_]*))?",
        scan,
        re.IGNORECASE,
    ):
        if match.group(1):
            table_aliases.add(match.group(1).lower())
    for table, column in sorted(_extract_qualified_columns(scan)):
        if table in cte_names or table in table_aliases:
            continue
        if table not in known_tables:
            return GuardrailResult(False, f"Unknown table qualifier: {table}.")
        if column == "*":
            continue
        if column not in {c.lower() for c in schema[table]}:
            return GuardrailResult(
                False, f"Unknown column: {table}.{column}."
            )

    # Unqualified columns must exist in at least one referenced real table.
    # Relaxed when the query defines a CTE, because CTE output columns are
    # not part of the schema (table-level validation still applies).
    if not cte_names:
        referenced_columns = set()
        for table in tables:
            if table in known_tables:
                referenced_columns.update(c.lower() for c in schema[table])
        identifiers = _extract_bare_identifiers(scan)
        identifiers -= tables
        identifiers -= cte_names
        identifiers -= table_aliases
        identifiers -= _extract_aliases(scan)
        identifiers -= {table for table, _ in _extract_qualified_columns(scan)}
        identifiers -= {column for _, column in _extract_qualified_columns(scan)}
        unknown_columns = sorted(c for c in identifiers if c not in referenced_columns)
        if unknown_columns:
            return GuardrailResult(
                False,
                "Unknown column(s): {}.".format(", ".join(unknown_columns)),
            )

    # Rule 6: enforce a LIMIT.
    rewritten = _enforce_limit(cleaned)
    return GuardrailResult(True, "Allowed.", rewritten)
