-- Retail dataset for the governed NL-to-SQL demo.
--
-- Load with scripts/seed_db.sh, which requires:
--   PGHOST, PGDATABASE, PGUSER, PGPASSWORD (admin credentials)
--   RO_PASSWORD (password to set for the read-only analytics_ro user)
--
-- The script is idempotent: it drops and recreates the retail tables, so
-- re-running it resets the demo data. It never contains credentials: the
-- analytics_ro password comes from the psql variable :ro_password.
--
-- Keep the tables and columns in sync with src/lambda/schema.py, which the
-- guardrails use as the allowlist.

BEGIN;

DROP TABLE IF EXISTS sales CASCADE;
DROP TABLE IF EXISTS inventory CASCADE;
DROP TABLE IF EXISTS customers CASCADE;
DROP TABLE IF EXISTS products CASCADE;
DROP TABLE IF EXISTS stores CASCADE;

CREATE TABLE stores (
    store_id    INTEGER PRIMARY KEY,
    store_name  TEXT NOT NULL,
    city        TEXT NOT NULL,
    state       TEXT NOT NULL,
    opened_date DATE NOT NULL
);

CREATE TABLE products (
    product_id   INTEGER PRIMARY KEY,
    product_name TEXT NOT NULL,
    category     TEXT NOT NULL,
    unit_price   NUMERIC(10, 2) NOT NULL CHECK (unit_price >= 0)
);

CREATE TABLE inventory (
    inventory_id     INTEGER PRIMARY KEY,
    store_id         INTEGER NOT NULL REFERENCES stores (store_id),
    product_id       INTEGER NOT NULL REFERENCES products (product_id),
    quantity_on_hand INTEGER NOT NULL CHECK (quantity_on_hand >= 0),
    last_restocked   DATE NOT NULL,
    UNIQUE (store_id, product_id)
);

CREATE TABLE customers (
    customer_id  INTEGER PRIMARY KEY,
    first_name   TEXT NOT NULL,
    last_name    TEXT NOT NULL,
    email        TEXT NOT NULL UNIQUE,
    loyalty_tier TEXT NOT NULL CHECK (loyalty_tier IN ('Bronze', 'Silver', 'Gold', 'Platinum'))
);

CREATE TABLE sales (
    sale_id      INTEGER PRIMARY KEY,
    store_id     INTEGER NOT NULL REFERENCES stores (store_id),
    product_id   INTEGER NOT NULL REFERENCES products (product_id),
    customer_id  INTEGER REFERENCES customers (customer_id),
    sale_date    DATE NOT NULL,
    quantity     INTEGER NOT NULL CHECK (quantity > 0),
    total_amount NUMERIC(10, 2) NOT NULL CHECK (total_amount >= 0)
);

-- Seed data: 3 stores, 12 products, 8 customers, inventory, 30 sales.
INSERT INTO stores (store_id, store_name, city, state, opened_date) VALUES
    (1, 'Downtown Flagship', 'Chicago', 'IL', '2019-03-15'),
    (2, 'Northside Market', 'Chicago', 'IL', '2021-06-01'),
    (3, 'Lakeshore Outlet', 'Milwaukee', 'WI', '2022-09-10');

INSERT INTO products (product_id, product_name, category, unit_price) VALUES
    (1, 'Wireless Headphones', 'Electronics', 129.99),
    (2, 'Bluetooth Speaker', 'Electronics', 79.99),
    (3, 'Smart Watch', 'Electronics', 199.99),
    (4, 'Running Shoes', 'Apparel', 89.99),
    (5, 'Denim Jacket', 'Apparel', 69.99),
    (6, 'Wool Scarf', 'Apparel', 34.99),
    (7, 'Coffee Maker', 'Home Goods', 59.99),
    (8, 'Ceramic Dinner Set', 'Home Goods', 84.99),
    (9, 'Desk Lamp', 'Home Goods', 39.99),
    (10, 'Organic Coffee Beans 1kg', 'Grocery', 18.99),
    (11, 'Olive Oil 750ml', 'Grocery', 14.99),
    (12, 'Trail Mix 500g', 'Grocery', 9.99);

INSERT INTO customers (customer_id, first_name, last_name, email, loyalty_tier) VALUES
    (1, 'Ava', 'Martinez', 'ava.martinez@example.com', 'Gold'),
    (2, 'Liam', 'Chen', 'liam.chen@example.com', 'Platinum'),
    (3, 'Maya', 'Patel', 'maya.patel@example.com', 'Silver'),
    (4, 'Noah', 'Kim', 'noah.kim@example.com', 'Bronze'),
    (5, 'Zoe', 'Garcia', 'zoe.garcia@example.com', 'Gold'),
    (6, 'Ethan', 'Novak', 'ethan.novak@example.com', 'Silver'),
    (7, 'Ruby', 'Singh', 'ruby.singh@example.com', 'Bronze'),
    (8, 'Owen', 'Brown', 'owen.brown@example.com', 'Gold');

INSERT INTO inventory (inventory_id, store_id, product_id, quantity_on_hand, last_restocked) VALUES
    (1, 1, 1, 42, '2026-11-10'), (2, 1, 2, 18, '2026-11-08'), (3, 1, 3, 7, '2026-11-12'),
    (4, 1, 4, 25, '2026-11-05'), (5, 1, 7, 12, '2026-11-09'), (6, 1, 10, 60, '2026-11-11'),
    (7, 2, 1, 15, '2026-11-07'), (8, 2, 4, 31, '2026-11-06'), (9, 2, 5, 9, '2026-11-10'),
    (10, 2, 8, 4, '2026-11-04'), (11, 2, 11, 48, '2026-11-12'), (12, 2, 12, 73, '2026-11-11'),
    (13, 3, 2, 22, '2026-11-09'), (14, 3, 3, 3, '2026-11-03'), (15, 3, 6, 27, '2026-11-08'),
    (16, 3, 9, 11, '2026-11-10'), (17, 3, 10, 35, '2026-11-12'), (18, 3, 12, 58, '2026-11-07');

INSERT INTO sales (sale_id, store_id, product_id, customer_id, sale_date, quantity, total_amount) VALUES
    (1, 1, 1, 1, '2026-10-05', 1, 129.99), (2, 1, 4, 2, '2026-10-05', 2, 179.98),
    (3, 2, 2, 3, '2026-10-06', 1, 79.99), (4, 1, 3, 2, '2026-10-07', 1, 199.99),
    (5, 3, 6, 4, '2026-10-08', 2, 69.98), (6, 1, 7, 5, '2026-10-09', 1, 59.99),
    (7, 2, 10, 6, '2026-10-10', 3, 56.97), (8, 1, 1, 7, '2026-10-12', 1, 129.99),
    (9, 3, 12, 8, '2026-10-13', 4, 39.96), (10, 2, 5, 1, '2026-10-14', 1, 69.99),
    (11, 1, 8, 3, '2026-10-15', 1, 84.99), (12, 1, 3, 5, '2026-10-18', 2, 399.98),
    (13, 2, 4, 2, '2026-10-20', 1, 89.99), (14, 3, 11, 6, '2026-10-21', 2, 29.98),
    (15, 1, 9, 4, '2026-10-22', 1, 39.99), (16, 2, 1, 8, '2026-10-24', 1, 129.99),
    (17, 1, 2, 1, '2026-10-26', 2, 159.98), (18, 3, 4, 7, '2026-10-28', 1, 89.99),
    (19, 2, 12, 5, '2026-10-30', 5, 49.95), (20, 1, 10, 3, '2026-11-01', 2, 37.98),
    (21, 1, 1, 2, '2026-11-03', 1, 129.99), (22, 2, 3, 8, '2026-11-04', 1, 199.99),
    (23, 3, 7, 6, '2026-11-05', 1, 59.99), (24, 1, 5, 4, '2026-11-06', 1, 69.99),
    (25, 2, 8, 1, '2026-11-08', 1, 84.99), (26, 1, 4, 5, '2026-11-09', 2, 179.98),
    (27, 3, 10, 7, '2026-11-10', 3, 56.97), (28, 2, 11, 3, '2026-11-11', 1, 14.99),
    (29, 1, 12, 8, '2026-11-12', 6, 59.94), (30, 1, 3, 1, '2026-11-13', 1, 199.99);

COMMIT;

-- Read-only user for the Lambda. The password comes from the psql variable
-- :ro_password (scripts/seed_db.sh passes -v ro_password="$RO_PASSWORD").
-- The Lambda connects as this user, so even a guardrail bypass could only
-- ever read: the role has SELECT and nothing else.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'analytics_ro') THEN
        CREATE USER analytics_ro WITH PASSWORD :'ro_password';
    ELSE
        ALTER USER analytics_ro WITH PASSWORD :'ro_password';
    END IF;
END
$$;

-- (CONNECT is granted to PUBLIC by default, so no explicit GRANT CONNECT
-- is needed for the read-only user.)
GRANT USAGE ON SCHEMA public TO analytics_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO analytics_ro;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO analytics_ro;
