BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL search_path = public;

-- Additive: existing inventory and core backup semantics are unchanged.
-- Serialize history cursor assignment through commit, including backfill.
ALTER TABLE consumption_records ADD COLUMN history_cursor BIGINT GENERATED ALWAYS AS IDENTITY;
CREATE UNIQUE INDEX consumption_history_cursor ON consumption_records(history_cursor);
ALTER TABLE consumption_records ADD COLUMN client_occurred_at TIMESTAMPTZ;
CREATE INDEX consumption_family_history ON consumption_records(family_id, history_cursor);
CREATE FUNCTION lock_consumption_history() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(723452019021::bigint);
  RETURN NULL;
END $$;
CREATE TRIGGER consumption_history_order BEFORE INSERT ON consumption_records
FOR EACH STATEMENT EXECUTE FUNCTION lock_consumption_history();

CREATE TABLE media_assets (
  family_id UUID NOT NULL REFERENCES families(id),
  id UUID NOT NULL,
  entity_type TEXT NOT NULL CHECK (entity_type IN ('product','intake_draft')),
  entity_id UUID NOT NULL,
  media_type TEXT NOT NULL CHECK (media_type IN ('product_image','instruction_image')),
  source_sha256 TEXT NOT NULL CHECK (length(source_sha256)=64),
  content BYTEA,
  mime_type TEXT NOT NULL DEFAULT 'image/jpeg',
  size_bytes INTEGER NOT NULL CHECK (size_bytes BETWEEN 1 AND 8388608),
  ocr_status TEXT NOT NULL DEFAULT 'pending' CHECK (ocr_status IN ('pending','processing','complete','failed')),
  ocr_text TEXT NOT NULL DEFAULT '',
  ocr_origin TEXT NOT NULL DEFAULT 'backend' CHECK(ocr_origin IN ('backend','local_migration')),
  ocr_error TEXT,
  processing_started_at TIMESTAMPTZ,
  created_by UUID NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  deleted_at TIMESTAMPTZ,
  PRIMARY KEY(family_id,id),
  FOREIGN KEY(family_id,created_by) REFERENCES family_members(family_id,user_id)
);
CREATE INDEX media_entity ON media_assets(family_id,entity_type,entity_id,created_at,id);

CREATE TABLE processing_ai_results (
 family_id UUID NOT NULL REFERENCES families(id),
 user_id UUID NOT NULL,
 id UUID NOT NULL,
 input_hash TEXT NOT NULL,
 status TEXT NOT NULL CHECK(status IN ('processing','running','complete','failed')),
 result JSONB,
 created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
 PRIMARY KEY(family_id,user_id,id),
 FOREIGN KEY(family_id,user_id) REFERENCES family_members(family_id,user_id)
);

-- A delete may arrive after an upload timeout but before upload commit.
-- Keep deletion intent even when the image row has not been inserted yet.
CREATE TABLE media_tombstones (
 family_id UUID NOT NULL REFERENCES families(id), id UUID NOT NULL,
 deleted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
 PRIMARY KEY(family_id,id)
);

COMMIT;
