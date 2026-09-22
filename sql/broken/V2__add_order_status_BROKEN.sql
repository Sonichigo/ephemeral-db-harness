-- The failure this pattern exists to catch.
--
-- Passes cleanly against an EMPTY database. Fails against one with rows:
-- NOT NULL with no DEFAULT cannot backfill existing rows. Run it against a
-- shared staging DB that someone truncated last week and it looks fine.
-- Run it against a fresh DB seeded with production-shaped data and it fails
-- here, in CI, instead of at 2am.
ALTER TABLE orders
    ADD COLUMN status TEXT NOT NULL;
