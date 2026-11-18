"""Retail schema shared by the prompt builder and the guardrails.

The guardrails validate generated SQL against this exact schema, so the
schema is defined once here and imported by both ``nl_to_sql.py`` (to build
the Bedrock prompt) and ``guardrails.py`` (to allowlist tables and columns).

Keep this in sync with ``sql/retail_schema.sql``.
"""

# table name -> ordered list of column names
SCHEMA = {
    "stores": [
        "store_id",
        "store_name",
        "city",
        "state",
        "opened_date",
    ],
    "products": [
        "product_id",
        "product_name",
        "category",
        "unit_price",
    ],
    "inventory": [
        "inventory_id",
        "store_id",
        "product_id",
        "quantity_on_hand",
        "last_restocked",
    ],
    "customers": [
        "customer_id",
        "first_name",
        "last_name",
        "email",
        "loyalty_tier",
    ],
    "sales": [
        "sale_id",
        "store_id",
        "product_id",
        "customer_id",
        "sale_date",
        "quantity",
        "total_amount",
    ],
}

TABLE_DESCRIPTIONS = {
    "stores": "Retail store locations.",
    "products": "Product catalog with prices.",
    "inventory": "On-hand stock per store and product.",
    "customers": "Customer records and loyalty tiers.",
    "sales": "One row per sale line item.",
}


def all_columns():
    """Return the set of every column name in the schema."""
    columns = set()
    for table_columns in SCHEMA.values():
        columns.update(table_columns)
    return columns


def render_schema_for_prompt():
    """Render the schema as DDL-style text for the Bedrock prompt."""
    lines = ["Database schema (PostgreSQL):", ""]
    for table, columns in SCHEMA.items():
        lines.append(f"Table {table} ({TABLE_DESCRIPTIONS[table]}):")
        lines.append(f"  {table}({', '.join(columns)})")
        lines.append("")
    lines.append("Relationships:")
    lines.append("  inventory.store_id -> stores.store_id")
    lines.append("  inventory.product_id -> products.product_id")
    lines.append("  sales.store_id -> stores.store_id")
    lines.append("  sales.product_id -> products.product_id")
    lines.append("  sales.customer_id -> customers.customer_id")
    return "\n".join(lines)
