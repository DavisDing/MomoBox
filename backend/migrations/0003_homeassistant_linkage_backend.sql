-- Complete the phase-four HA linkage persistence contract.
-- This migration is additive and does not alter 0002.
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL TIME ZONE 'UTC';
SET LOCAL search_path = public;

-- HA-originated inventory records have no mobile sync device. The actor and
-- operation are still recorded in the HA deduction/audit tables; allowing a
-- NULL device keeps the existing inventory history usable without inventing a
-- fake device identity.
ALTER TABLE consumption_records ALTER COLUMN device_id DROP NOT NULL;

CREATE INDEX IF NOT EXISTS ix_ha_appliance_runs_family_run
    ON ha_appliance_runs (family_id, appliance_run_id);
CREATE INDEX IF NOT EXISTS ix_ha_linkage_suggestions_family_created
    ON ha_linkage_suggestions (family_id, created_at DESC);

-- The Go migration runner records the exact file checksum in schema_migrations.

COMMIT;
