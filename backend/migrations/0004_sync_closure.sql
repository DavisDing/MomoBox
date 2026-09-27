-- Sync persistence extensions. The Go runner owns schema_migrations and stores
-- the SHA-256 of these exact bytes; do not insert a placeholder checksum here.
BEGIN;
SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL TIME ZONE 'UTC';
SET LOCAL search_path = public;

CREATE TABLE IF NOT EXISTS sync_bootstrap_checkpoints (
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    device_id UUID NOT NULL,
    local_workspace_id TEXT,
    mode TEXT,
    state TEXT NOT NULL DEFAULT 'pending',
    snapshot_cursor BIGINT NOT NULL DEFAULT 0,
    checkpoint UUID NOT NULL DEFAULT gen_random_uuid(),
    confirmed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (family_id, device_id),
    CONSTRAINT sync_bootstrap_checkpoints_device_fk FOREIGN KEY (device_id, family_id)
        REFERENCES sync_devices(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT sync_bootstrap_checkpoints_state_chk CHECK (state IN ('pending', 'confirmed', 'applying', 'completed', 'failed')),
    CONSTRAINT sync_bootstrap_checkpoints_mode_chk CHECK (mode IS NULL OR mode IN ('join_and_merge', 'create_new_family', 'keep_local_only')),
    CONSTRAINT sync_bootstrap_checkpoints_cursor_chk CHECK (snapshot_cursor >= 0)
);

CREATE TABLE IF NOT EXISTS sync_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    device_id UUID,
    user_id UUID,
    action TEXT NOT NULL,
    resource_type TEXT NOT NULL,
    resource_id TEXT,
    details JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT sync_audit_log_device_fk FOREIGN KEY (device_id, family_id)
        REFERENCES sync_devices(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT sync_audit_log_user_fk FOREIGN KEY (family_id, user_id)
        REFERENCES family_members(family_id, user_id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS ix_sync_audit_log_family_created ON sync_audit_log(family_id, created_at DESC);

CREATE TABLE IF NOT EXISTS sync_tombstones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    entity TEXT NOT NULL,
    entity_id UUID NOT NULL,
    version BIGINT NOT NULL,
    change_id UUID,
    deleted_by_device UUID,
    deleted_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    retained_until TIMESTAMPTZ,
    CONSTRAINT sync_tombstones_family_entity_version_key UNIQUE(family_id, entity, entity_id, version),
    CONSTRAINT sync_tombstones_device_fk FOREIGN KEY (deleted_by_device, family_id)
        REFERENCES sync_devices(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT sync_tombstones_version_chk CHECK (version >= 1)
);
CREATE INDEX IF NOT EXISTS ix_sync_tombstones_family_entity ON sync_tombstones(family_id, entity, entity_id, version DESC);

-- Incoming conflicting changes do not exist in change_log yet. Preserve their
-- client change_id as data, not a foreign key to an accepted change.
ALTER TABLE conflict_records DROP CONSTRAINT IF EXISTS conflict_records_change_fk;
ALTER TABLE conflict_records ADD COLUMN IF NOT EXISTS operation TEXT;
ALTER TABLE conflict_records DROP CONSTRAINT IF EXISTS conflict_records_operation_chk;
ALTER TABLE conflict_records ADD CONSTRAINT conflict_records_operation_chk
    CHECK (operation IS NULL OR operation IN ('entity_upsert', 'entity_delete', 'inventory_command', 'home_assistant_command'));
CREATE UNIQUE INDEX IF NOT EXISTS ux_conflict_records_family_device_change
    ON conflict_records(family_id, device_id, change_id) WHERE change_id IS NOT NULL;

-- Reserved for server-originated command summaries; ordinary HA sync commands
-- currently use sync_idempotency without fabricating a change_log entity.
ALTER TABLE change_log DROP CONSTRAINT IF EXISTS change_log_operation_chk;
ALTER TABLE change_log ADD CONSTRAINT change_log_operation_chk
    CHECK (operation IN ('entity_upsert', 'entity_delete', 'inventory_command', 'home_assistant_command'));
COMMIT;
