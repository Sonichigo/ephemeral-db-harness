-- Post-migration verification. Any failure aborts the pipeline, which is
-- the entire point of provisioning the database in the first place.
--
-- The row-count assertions read their expected values from ci_expectations,
-- which the seed step populated. Nothing here hardcodes how many rows the seed
-- inserted, so adding seed data does not silently invalidate the checks.
DO $$
DECLARE
    expected_orders BIGINT;
BEGIN
    -- 0. the checks can only mean something if the seed actually ran
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables
                   WHERE table_name = 'ci_expectations'
                     AND table_schema = current_schema()) THEN
        RAISE EXCEPTION
            'FAIL: ci_expectations missing — seed step did not run, so these '
            'checks would pass against an empty database';
    END IF;

    SELECT seeded_orders INTO expected_orders FROM ci_expectations;

    IF expected_orders IS NULL OR expected_orders = 0 THEN
        RAISE EXCEPTION
            'FAIL: seed recorded % orders — verifying a migration against an '
            'empty table proves nothing', expected_orders;
    END IF;

    -- 1. the new column exists and is NOT NULL
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'orders' AND column_name = 'status'
          AND is_nullable = 'NO'
    ) THEN
        RAISE EXCEPTION 'FAIL: orders.status missing or nullable';
    END IF;

    -- 2. pre-existing rows survived the migration
    IF (SELECT count(*) FROM orders) <> expected_orders THEN
        RAISE EXCEPTION 'FAIL: expected % seeded orders, found %',
            expected_orders, (SELECT count(*) FROM orders);
    END IF;

    -- 3. no row was left with an unset status
    IF EXISTS (SELECT 1 FROM orders WHERE status IS NULL OR status = '') THEN
        RAISE EXCEPTION 'FAIL: rows exist with unset status';
    END IF;

    -- 4. the backfill used the intended default on every pre-existing row
    IF (SELECT count(*) FROM orders WHERE status = 'pending') <> expected_orders THEN
        RAISE EXCEPTION
            'FAIL: backfill did not apply the pending default — % of % rows '
            'have it',
            (SELECT count(*) FROM orders WHERE status = 'pending'),
            expected_orders;
    END IF;

    -- 5. the index actually got created
    IF NOT EXISTS (
        SELECT 1 FROM pg_indexes
        WHERE tablename = 'orders' AND indexname = 'idx_orders_status'
    ) THEN
        RAISE EXCEPTION 'FAIL: idx_orders_status missing';
    END IF;

    -- 6. the constraint rejects garbage
    BEGIN
        INSERT INTO orders (customer_id, total_cents, status)
        VALUES (1, 100, 'not_a_real_status');
        RAISE EXCEPTION 'FAIL: chk_orders_status did not reject bad value';
    EXCEPTION WHEN check_violation THEN
        NULL;  -- expected
    END;

    RAISE NOTICE 'PASS: all 6 checks passed against % seeded orders',
        expected_orders;
END $$;
