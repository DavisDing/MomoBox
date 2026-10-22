-- Additive initial-state import. Earlier migration bytes remain immutable.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL TIME ZONE 'UTC';
SET LOCAL search_path = public;

ALTER TABLE families ADD COLUMN time_zone TEXT NOT NULL DEFAULT 'Asia/Shanghai';
ALTER TABLE families ADD CONSTRAINT families_time_zone_length_chk CHECK (char_length(time_zone) BETWEEN 1 AND 255);
ALTER TABLE products ADD COLUMN location TEXT;
ALTER TABLE products ADD COLUMN unit TEXT NOT NULL DEFAULT '件';
ALTER TABLE products ADD COLUMN low_stock_threshold INTEGER NOT NULL DEFAULT 1 CHECK (low_stock_threshold > 0);
ALTER TABLE product_batches ADD COLUMN batch_no TEXT;
ALTER TABLE product_batches ADD COLUMN is_opened BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE shopping_items ADD COLUMN category TEXT;
ALTER TABLE shopping_items ADD COLUMN reason TEXT NOT NULL DEFAULT '手动添加';

CREATE TABLE sync_import_plans (
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    import_id UUID NOT NULL,
    user_id UUID NOT NULL,
    device_id UUID NOT NULL,
    local_workspace_id TEXT NOT NULL,
    fingerprint TEXT NOT NULL CHECK (fingerprint ~ '^[0-9a-f]{64}$'),
    checkpoint UUID NOT NULL DEFAULT gen_random_uuid(),
    state TEXT NOT NULL CHECK (state IN ('prepared', 'completed')),
    manifest JSONB NOT NULL CHECK (jsonb_typeof(manifest) = 'object'),
    receipt JSONB NOT NULL CHECK (jsonb_typeof(receipt) = 'object'),
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMPTZ,
    PRIMARY KEY (family_id, import_id),
    FOREIGN KEY (family_id, user_id) REFERENCES family_members(family_id, user_id) ON DELETE RESTRICT,
    FOREIGN KEY (device_id, family_id) REFERENCES sync_devices(id, family_id) ON DELETE RESTRICT
);

-- Archives do not reference mutable/deleted business objects. UUIDs identify
-- the source records; no original operator or device is invented.
CREATE TABLE imported_stock_history (
    cursor BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    id UUID NOT NULL,
    import_id UUID NOT NULL,
    local_workspace_id TEXT NOT NULL,
    product_id UUID NOT NULL,
    batch_id UUID,
    type TEXT NOT NULL CHECK (type IN ('intake','restock','consume','discard','adjust')),
    quantity INTEGER NOT NULL CHECK (quantity <> 0),
    note TEXT,
    occurred_at TIMESTAMPTZ NOT NULL,
    source_time_zone TEXT,
    imported_by_user_id UUID NOT NULL,
    imported_by_device_id UUID NOT NULL,
    received_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (family_id, id),
    FOREIGN KEY (family_id, import_id) REFERENCES sync_import_plans(family_id, import_id) ON DELETE RESTRICT,
    FOREIGN KEY (family_id, imported_by_user_id) REFERENCES family_members(family_id, user_id) ON DELETE RESTRICT,
    FOREIGN KEY (imported_by_device_id, family_id) REFERENCES sync_devices(id, family_id) ON DELETE RESTRICT,
    CHECK ((type IN ('intake','restock') AND quantity > 0) OR (type IN ('consume','discard') AND quantity < 0) OR type = 'adjust')
);
CREATE INDEX ix_imported_stock_history_family_cursor ON imported_stock_history(family_id, cursor);

-- Hold allocation order to commit so an observed archive high-watermark cannot
-- skip a smaller cursor that commits later. Imports serialize on this table.
CREATE OR REPLACE FUNCTION serialize_import_history_cursor_allocation()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    PERFORM pg_advisory_xact_lock(hashtextextended('momobox:import_history:cursor-order', 0));
    RETURN NULL;
END;
$$;
CREATE TRIGGER imported_stock_history_cursor_order BEFORE INSERT ON imported_stock_history
FOR EACH STATEMENT EXECUTE FUNCTION serialize_import_history_cursor_allocation();
COMMIT;
