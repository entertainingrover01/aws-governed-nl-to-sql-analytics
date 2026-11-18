"""Unit tests for the deterministic SQL guardrails (stdlib unittest only).

Run from the repo root:

    python3 -m unittest discover -s tests -v
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src", "lambda"))

from guardrails import MAX_LIMIT, validate_sql  # noqa: E402
from schema import SCHEMA  # noqa: E402


def check(sql):
    return validate_sql(sql, SCHEMA)


class TestAllowedQueries(unittest.TestCase):
    def test_simple_select_passes(self):
        result = check("SELECT product_name, unit_price FROM products")
        self.assertTrue(result.allowed, result.reason)

    def test_select_star_passes(self):
        result = check("SELECT * FROM customers")
        self.assertTrue(result.allowed, result.reason)

    def test_join_across_allowlisted_tables_passes(self):
        result = check(
            "SELECT s.store_name, SUM(sa.total_amount) AS revenue "
            "FROM sales sa JOIN stores s ON sa.store_id = s.store_id "
            "GROUP BY s.store_name ORDER BY revenue DESC"
        )
        self.assertTrue(result.allowed, result.reason)

    def test_aggregate_with_group_by_passes(self):
        result = check(
            "SELECT category, COUNT(*) AS product_count FROM products "
            "GROUP BY category"
        )
        self.assertTrue(result.allowed, result.reason)

    def test_subquery_passes(self):
        result = check(
            "SELECT product_name FROM products WHERE product_id IN "
            "(SELECT product_id FROM sales WHERE quantity > 10)"
        )
        self.assertTrue(result.allowed, result.reason)

    def test_with_cte_passes(self):
        result = check(
            "WITH top_products AS ("
            "  SELECT product_id, SUM(total_amount) AS revenue FROM sales "
            "  GROUP BY product_id"
            ") SELECT product_id, revenue FROM top_products ORDER BY revenue DESC"
        )
        self.assertTrue(result.allowed, result.reason)

    def test_case_insensitive_keywords_pass(self):
        result = check("select product_name from products")
        self.assertTrue(result.allowed, result.reason)

    def test_keyword_inside_string_literal_does_not_block(self):
        # A product literally named 'DROP' must not trip the keyword filter.
        result = check("SELECT * FROM products WHERE product_name = 'DROP'")
        self.assertTrue(result.allowed, result.reason)

    def test_trailing_semicolon_is_fine(self):
        result = check("SELECT * FROM stores;")
        self.assertTrue(result.allowed, result.reason)

    def test_date_functions_pass(self):
        result = check(
            "SELECT DATE_TRUNC('month', sale_date) AS month, "
            "SUM(total_amount) AS revenue FROM sales "
            "GROUP BY month ORDER BY month"
        )
        self.assertTrue(result.allowed, result.reason)

    def test_order_by_alias_passes(self):
        result = check(
            "SELECT category, SUM(unit_price) AS total FROM products "
            "GROUP BY category ORDER BY total DESC"
        )
        self.assertTrue(result.allowed, result.reason)


class TestLimitEnforcement(unittest.TestCase):
    def test_limit_appended_when_missing(self):
        result = check("SELECT * FROM sales")
        self.assertTrue(result.allowed, result.reason)
        self.assertTrue(result.sql.rstrip().rstrip(";").upper().endswith(f"LIMIT {MAX_LIMIT}"))

    def test_existing_small_limit_is_kept(self):
        result = check("SELECT * FROM sales LIMIT 5")
        self.assertTrue(result.allowed, result.reason)
        self.assertIn("LIMIT 5", result.sql.upper())

    def test_oversized_limit_is_capped(self):
        result = check("SELECT * FROM sales LIMIT 5000")
        self.assertTrue(result.allowed, result.reason)
        self.assertIn(f"LIMIT {MAX_LIMIT}", result.sql.upper())
        self.assertNotIn("LIMIT 5000", result.sql.upper())


class TestBlockedStatements(unittest.TestCase):
    def test_drop_is_blocked(self):
        result = check("DROP TABLE sales")
        self.assertFalse(result.allowed)
        self.assertIn("SELECT", result.reason)

    def test_delete_is_blocked(self):
        result = check("DELETE FROM sales WHERE sale_date < '2025-01-01'")
        self.assertFalse(result.allowed)

    def test_update_is_blocked(self):
        result = check("UPDATE products SET unit_price = 0 WHERE product_id = 1")
        self.assertFalse(result.allowed)

    def test_insert_is_blocked(self):
        result = check("INSERT INTO products VALUES (99, 'Widget', 'Gadgets', 9.99)")
        self.assertFalse(result.allowed)

    def test_select_into_is_blocked(self):
        result = check("SELECT * INTO stolen_copy FROM customers")
        self.assertFalse(result.allowed)
        self.assertIn("INTO", result.reason)

    def test_stacked_statements_are_blocked(self):
        result = check("SELECT * FROM sales; DROP TABLE sales")
        self.assertFalse(result.allowed)
        self.assertIn("Multiple statements", result.reason)

    def test_keyword_hidden_in_comment_is_blocked(self):
        result = check("SELECT * FROM sales /* DROP TABLE sales */")
        # The comment is stripped, so the SELECT itself is fine...
        self.assertTrue(result.allowed, result.reason)
        # ...but a stacked DROP after the comment is still caught.
        result = check("SELECT * FROM sales; /* cleanup */ DROP TABLE sales")
        self.assertFalse(result.allowed)


class TestSchemaAllowlist(unittest.TestCase):
    def test_unknown_table_is_blocked(self):
        result = check("SELECT * FROM employees")
        self.assertFalse(result.allowed)
        self.assertIn("employees", result.reason)

    def test_unknown_column_is_blocked(self):
        result = check("SELECT salary FROM customers")
        self.assertFalse(result.allowed)
        self.assertIn("salary", result.reason)

    def test_unknown_qualified_column_is_blocked(self):
        result = check("SELECT sales.password FROM sales")
        self.assertFalse(result.allowed)
        self.assertIn("sales.password", result.reason)

    def test_union_exfiltration_to_unknown_table_is_blocked(self):
        result = check(
            "SELECT email FROM customers "
            "UNION SELECT username FROM users"
        )
        self.assertFalse(result.allowed)
        self.assertIn("users", result.reason)

    def test_union_exfiltration_to_system_catalog_is_blocked(self):
        result = check(
            "SELECT email FROM customers "
            "UNION SELECT table_name FROM information_schema.tables"
        )
        self.assertFalse(result.allowed)
        self.assertIn("information_schema", result.reason)

    def test_information_schema_is_blocked(self):
        result = check("SELECT table_name FROM information_schema.tables")
        self.assertFalse(result.allowed)

    def test_pg_catalog_is_blocked(self):
        result = check("SELECT usename FROM pg_catalog.pg_user")
        self.assertFalse(result.allowed)

    def test_no_table_is_blocked(self):
        result = check("SELECT 1")
        self.assertFalse(result.allowed)

    def test_empty_sql_is_blocked(self):
        result = check("")
        self.assertFalse(result.allowed)
        result = check("   ")
        self.assertFalse(result.allowed)


if __name__ == "__main__":
    unittest.main()
