-- V2: the migration under test.
-- Adds a status column WITH a default, so existing rows can be backfilled.
ALTER TABLE orders
    ADD COLUMN status TEXT NOT NULL DEFAULT 'pending';

ALTER TABLE orders
    ADD CONSTRAINT chk_orders_status
    CHECK (status IN ('pending', 'paid', 'shipped', 'cancelled'));

CREATE INDEX idx_orders_status ON orders(status);
