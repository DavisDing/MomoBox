BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL TIME ZONE 'UTC';
-- Preserve opaque AEAD key identifiers; old integer values retain their text.
SET LOCAL search_path = public;
ALTER TABLE ha_integrations DROP CONSTRAINT ha_integrations_key_version_chk;
ALTER TABLE ha_integrations ALTER COLUMN key_version DROP DEFAULT;
ALTER TABLE ha_integrations ALTER COLUMN key_version TYPE TEXT USING key_version::text;
ALTER TABLE ha_integrations ALTER COLUMN key_version SET DEFAULT '1';
ALTER TABLE ha_integrations ADD CONSTRAINT ha_integrations_key_version_chk
    CHECK (char_length(key_version) BETWEEN 1 AND 128 AND key_version !~ '[[:space:][:cntrl:]]');

-- A zero-stock discard is an auditable state transition, not a deduction.
ALTER TABLE consumption_records DROP CONSTRAINT consumption_records_quantity_chk;
ALTER TABLE consumption_records ADD CONSTRAINT consumption_records_quantity_chk CHECK (
    (record_type = 'consume' AND quantity_change < 0)
    OR (record_type = 'discard' AND quantity_change <= 0)
    OR (record_type = 'restock' AND quantity_change > 0)
    OR (record_type = 'adjust' AND quantity_change <> 0)
);

-- Imported state-only discard history must retain the same audit semantics.
ALTER TABLE imported_stock_history DROP CONSTRAINT imported_stock_history_quantity_check;
ALTER TABLE imported_stock_history DROP CONSTRAINT imported_stock_history_check;
ALTER TABLE imported_stock_history ADD CONSTRAINT imported_stock_history_quantity_chk CHECK (
    (type IN ('intake','restock') AND quantity > 0)
    OR (type = 'consume' AND quantity < 0)
    OR (type = 'discard' AND quantity <= 0)
    OR (type = 'adjust' AND quantity <> 0)
);

-- This ledger is committed before a command leaves the NAS. Unknown/pending
-- executions are never automatically resent. Receipts outlive sync retries.
CREATE TABLE ha_command_executions (
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    request_id UUID NOT NULL,
    fingerprint TEXT NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('pending', 'succeeded', 'rejected', 'unknown')),
    response_payload JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (family_id, request_id),
    CHECK ((status = 'succeeded') = (response_payload IS NOT NULL))
);

COMMIT;
