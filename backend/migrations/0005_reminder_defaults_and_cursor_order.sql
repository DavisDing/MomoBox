-- Preserve existing explicit reminder values. New records share the client's
-- thirty-day default. The migration runner owns the transaction/checksum.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL TIME ZONE 'UTC';
SET LOCAL search_path = public;

ALTER TABLE reminder_settings ALTER COLUMN expiry_warning_days SET DEFAULT 30;

-- identity values alone do not imply commit order. Serialize INSERT statements
-- before any row/default expression allocates a cursor, holding the lock until
-- commit/rollback. This covers both sync and direct inventory command paths.
-- A single global lock is deliberate: the identity sequence is global too.
CREATE OR REPLACE FUNCTION serialize_change_log_cursor_allocation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('momobox:change_log:cursor-order', 0));
    RETURN NULL;
END;
$$;

-- Per-session sequence caches can allocate a lower range after another session
-- has committed a higher range, even with the statement lock. Keep CACHE 1.
DO $$
DECLARE
    cursor_sequence regclass;
BEGIN
    cursor_sequence := pg_get_serial_sequence('public.change_log', 'cursor')::regclass;
    IF cursor_sequence IS NULL THEN
        RAISE EXCEPTION 'change_log.cursor identity sequence is missing';
    END IF;
    EXECUTE format('ALTER SEQUENCE %s CACHE 1', cursor_sequence);
END;
$$;

DROP TRIGGER IF EXISTS change_log_cursor_order ON change_log;
CREATE TRIGGER change_log_cursor_order
BEFORE INSERT ON change_log
FOR EACH STATEMENT
EXECUTE FUNCTION serialize_change_log_cursor_allocation();

COMMIT;
