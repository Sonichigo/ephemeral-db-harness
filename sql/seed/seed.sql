-- Seed data shaped like production, including the edge cases that an
-- empty test database will never surface.
INSERT INTO customers (email) VALUES
    ('alice@example.com'),
    ('bob@example.com'),
    ('carol@example.com');

INSERT INTO orders (customer_id, total_cents) VALUES
    (1, 4999),
    (1, 0),        -- edge case: zero-value order
    (2, 129900),   -- edge case: large order
    (3, 1);        -- edge case: minimum non-zero

-- Record what was seeded, so the post-migration checks can assert "every row
-- that existed before the migration still exists and was backfilled" without
-- hardcoding a row count. Add a row to the block above and the checks keep
-- working.
--
-- CI bookkeeping, not application schema: this table is created by the seed
-- step, never by a migration, so it cannot reach a real environment.
CREATE TABLE ci_expectations (
    seeded_customers BIGINT NOT NULL,
    seeded_orders    BIGINT NOT NULL
);

INSERT INTO ci_expectations (seeded_customers, seeded_orders)
SELECT (SELECT count(*) FROM customers), (SELECT count(*) FROM orders);
