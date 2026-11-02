BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL search_path = public;

-- Additive only: existing conflicts and their historical resolutions remain
-- unchanged. A receipt and its resolution commit in the same transaction.
CREATE TABLE sync_conflict_resolution_receipts (
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    device_id UUID NOT NULL,
    idempotency_key TEXT NOT NULL CHECK (char_length(idempotency_key) BETWEEN 16 AND 255),
    fingerprint TEXT NOT NULL,
    response_payload JSONB NOT NULL CHECK (jsonb_typeof(response_payload) = 'object'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (family_id, device_id, idempotency_key),
    FOREIGN KEY (device_id, family_id) REFERENCES sync_devices(id, family_id) ON DELETE RESTRICT
);

COMMIT;
