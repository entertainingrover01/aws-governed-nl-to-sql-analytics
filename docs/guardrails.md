# Guardrails

The guardrails are the enforcement layer of this project: deterministic
checks, standard library only, in `src/lambda/guardrails.py`. They run on
every generated statement **before** anything touches the database, and the
prompt is never trusted — the model is asked to generate safe SQL, but the
guardrails are what make it safe.

## Rules

| # | Rule | How it is enforced |
|---|---|---|
| 1 | Single statement, `SELECT`/`WITH` only | After stripping comments, the statement must start with `SELECT` or `WITH` and contain no `;` except a single trailing one. Stacked statements (`SELECT ...; DROP TABLE ...`) are rejected. |
| 2 | No mutating or administrative keywords | Whole-word, case-insensitive blocklist: `DROP`, `DELETE`, `UPDATE`, `INSERT`, `ALTER`, `TRUNCATE`, `GRANT`, `REVOKE`, `COPY`, `CREATE`, `INTO` (blocks `SELECT ... INTO`), `MERGE`, `CALL`, `DO`, `VACUUM`, `ANALYZE`, `COMMENT`, `SECURITY`. String literals are stripped before scanning, so a product named `'DROP'` does not trip the filter. |
| 3 | No system catalogs | `information_schema` and `pg_catalog` are forbidden anywhere in the statement, including inside `UNION` exfiltration attempts. |
| 4 | Tables must be allowlisted | Every table after `FROM`/`JOIN` must exist in `schema.py` (`stores`, `products`, `inventory`, `customers`, `sales`) or be a CTE defined in the query itself. |
| 5 | Columns must be allowlisted | `table.column` references are checked against that table's columns. Bare column names must exist in at least one referenced table. Aliases (`AS revenue`) and table aliases are recognised so `ORDER BY revenue` is not falsely rejected. |
| 6 | A `LIMIT` is enforced | A query with no `LIMIT` gets `LIMIT 100` appended; a `LIMIT` above 100 is capped at 100. The rewritten SQL is what gets executed (and audited). |

## How the checks are ordered

`validate_sql` runs the checks in this order and returns the first failure,
with a human-readable reason that the API returns to the caller:

1. Empty statement.
2. Multiple statements.
3. Not `SELECT`/`WITH`.
4. Blocked keyword.
5. Forbidden schema (`information_schema`, `pg_catalog`).
6. Unknown table.
7. Unknown column.
8. LIMIT enforcement (rewrite, not a rejection).

## Known limitations

These are deliberate trade-offs of a regex-and-allowlist validator, stated
here so reviewers can judge them:

- **CTE column checks are relaxed.** For queries with a `WITH` clause,
  unqualified column validation is skipped, because CTE output columns are
  not in the schema. Table-level validation still applies, and qualified
  `table.column` references against real tables are still checked.
- **The validator is heuristic, not a SQL parser.** It works on the
  well-formed SQL this project's prompt produces (single `SELECT`, standard
  joins, aggregates, subqueries, CTEs). Exotic but valid SQL could be
  falsely rejected; the failure mode is a rejected query, never an unsafe
  one — every check errs toward blocking.
- **The guardrails are one of three layers.** Even if a statement slipped
  past them, the `analytics_ro` database role has only `SELECT` privileges
  and every execution runs in a read-only transaction.

## Tests

`tests/test_guardrails.py` covers every rule with pass and fail cases
(30 tests, stdlib `unittest` only):

```bash
python3 -m unittest discover -s tests -v
```

Fail cases include a `DROP` attempt, a `DELETE`, a `SELECT ... INTO`, a
stacked-statement attack, a `UNION` exfiltration to an unknown table and to
`information_schema`, unknown tables and columns, and a query with no
`LIMIT` (which gets one appended rather than being rejected).
