-- MomoBox NAS PostgreSQL schema, migration 0001.
--
-- This migration is intentionally idempotent. It may be executed again after a
-- successful run; existing objects are preserved and the migration record is
-- not duplicated. Future incompatible changes must use a new versioned file.

BEGIN;

-- Serialize migration execution even when more than one backend container
-- starts at the same time. The lock is transaction-scoped.
SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));

SET LOCAL TIME ZONE 'UTC';
SET LOCAL search_path = public;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version       BIGINT PRIMARY KEY,
    name          TEXT NOT NULL,
    checksum      TEXT NOT NULL,
    applied_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE FUNCTION momo_set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;

-- -------------------------------------------------------------------------
-- Identity, families, membership, and client devices
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           TEXT NOT NULL,
    password_hash   TEXT NOT NULL,
    nickname        TEXT NOT NULL,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at      TIMESTAMPTZ,
    CONSTRAINT users_email_length_chk CHECK (char_length(email) BETWEEN 3 AND 320),
    CONSTRAINT users_password_hash_length_chk CHECK (char_length(password_hash) > 0),
    CONSTRAINT users_nickname_length_chk CHECK (char_length(nickname) BETWEEN 1 AND 80)
);

COMMENT ON COLUMN users.password_hash IS 'bcrypt hash only; never store a plaintext password.';
COMMENT ON COLUMN users.email IS 'Backend must normalize email before insert/update; uniqueness is case-insensitive.';

CREATE UNIQUE INDEX IF NOT EXISTS ux_users_email_active
    ON users (lower(email))
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_users_deleted_at ON users (deleted_at);

CREATE TABLE IF NOT EXISTS families (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                TEXT NOT NULL,
    created_by_user_id   UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT families_name_length_chk CHECK (char_length(name) BETWEEN 1 AND 120)
);

CREATE INDEX IF NOT EXISTS ix_families_created_by_user ON families (created_by_user_id);
CREATE INDEX IF NOT EXISTS ix_families_deleted_at ON families (deleted_at);

CREATE TABLE IF NOT EXISTS family_members (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id       UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    user_id         UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    role            TEXT NOT NULL,
    joined_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at      TIMESTAMPTZ,
    CONSTRAINT family_members_role_chk CHECK (role IN ('owner', 'admin', 'member')),
    CONSTRAINT family_members_family_user_key UNIQUE (family_id, user_id),
    CONSTRAINT family_members_id_family_key UNIQUE (id, family_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_family_members_one_active_owner
    ON family_members (family_id)
    WHERE role = 'owner' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_family_members_family_active
    ON family_members (family_id, deleted_at, role);
CREATE INDEX IF NOT EXISTS ix_family_members_user ON family_members (user_id);
CREATE UNIQUE INDEX IF NOT EXISTS ux_family_members_user_family
    ON family_members (user_id, family_id);

-- A user may belong to multiple families, but access tokens and sync devices
-- are always scoped to one explicitly selected current family. The composite
-- foreign key prevents selecting a family in which the user is not a member.
ALTER TABLE users
    ADD COLUMN IF NOT EXISTS current_family_id UUID;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'users_current_family_membership_fk'
          AND conrelid = 'users'::regclass
    ) THEN
        ALTER TABLE users
            ADD CONSTRAINT users_current_family_membership_fk
            FOREIGN KEY (id, current_family_id)
            REFERENCES family_members (user_id, family_id)
            MATCH SIMPLE
            ON DELETE RESTRICT;
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS ix_users_current_family ON users (current_family_id);

CREATE TABLE IF NOT EXISTS sync_devices (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id       UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    user_id         UUID NOT NULL,
    device_name     TEXT NOT NULL,
    platform        TEXT NOT NULL,
    app_version      TEXT,
    last_seen_at     TIMESTAMPTZ,
    last_sync_cursor BIGINT NOT NULL DEFAULT 0,
    last_sync_at     TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at      TIMESTAMPTZ,
    deleted_at      TIMESTAMPTZ,
    CONSTRAINT sync_devices_family_member_fk
        FOREIGN KEY (family_id, user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT sync_devices_platform_chk CHECK (platform IN ('android', 'ios', 'other')),
    CONSTRAINT sync_devices_name_length_chk CHECK (char_length(device_name) BETWEEN 1 AND 120),
    CONSTRAINT sync_devices_last_sync_cursor_chk CHECK (last_sync_cursor >= 0),
    CONSTRAINT sync_devices_id_family_key UNIQUE (id, family_id)
);

CREATE INDEX IF NOT EXISTS ix_sync_devices_family_user_active
    ON sync_devices (family_id, user_id, deleted_at);
CREATE INDEX IF NOT EXISTS ix_sync_devices_last_seen
    ON sync_devices (family_id, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    family_id           UUID,
    device_id           UUID,
    token_hash          BYTEA NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    revoked_at          TIMESTAMPTZ,
    replaced_by_token_id UUID REFERENCES refresh_tokens(id) ON DELETE SET NULL,
    last_used_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT refresh_tokens_token_hash_key UNIQUE (token_hash),
    CONSTRAINT refresh_tokens_device_family_fk
        FOREIGN KEY (device_id, family_id)
        REFERENCES sync_devices (id, family_id)
        MATCH FULL
        ON DELETE RESTRICT,
    CONSTRAINT refresh_tokens_expiry_chk CHECK (expires_at > created_at)
);

COMMENT ON COLUMN refresh_tokens.token_hash IS 'Hash of the opaque refresh token, optionally peppered by the backend; never store the raw token.';
CREATE INDEX IF NOT EXISTS ix_refresh_tokens_user_active
    ON refresh_tokens (user_id, revoked_at, expires_at);
CREATE INDEX IF NOT EXISTS ix_refresh_tokens_device_active
    ON refresh_tokens (device_id, revoked_at);

CREATE TABLE IF NOT EXISTS family_invites (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    created_by_user_id   UUID NOT NULL,
    code_hash           BYTEA NOT NULL,
    expires_at          TIMESTAMPTZ NOT NULL,
    max_uses            INTEGER NOT NULL,
    used_count          INTEGER NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at          TIMESTAMPTZ,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT family_invites_creator_fk
        FOREIGN KEY (family_id, created_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT family_invites_code_key UNIQUE (family_id, code_hash),
    CONSTRAINT family_invites_uses_chk CHECK (max_uses BETWEEN 1 AND 20),
    CONSTRAINT family_invites_used_count_chk CHECK (used_count BETWEEN 0 AND max_uses),
    CONSTRAINT family_invites_expiry_chk CHECK (expires_at > created_at),
    CONSTRAINT family_invites_id_family_key UNIQUE (id, family_id)
);

COMMENT ON COLUMN family_invites.code_hash IS 'Hash of the invitation code; never store the user-visible code in PostgreSQL.';
CREATE INDEX IF NOT EXISTS ix_family_invites_family_active
    ON family_invites (family_id, expires_at, revoked_at, deleted_at);

-- -------------------------------------------------------------------------
-- Family-scoped inventory and shopping data
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS categories (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    name                TEXT NOT NULL,
    color               TEXT,
    sort_order          INTEGER NOT NULL DEFAULT 0,
    created_by_user_id   UUID,
    updated_by_device   UUID,
    version             BIGINT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT categories_creator_fk
        FOREIGN KEY (family_id, created_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT categories_updated_device_fk
        FOREIGN KEY (updated_by_device, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT categories_name_length_chk CHECK (char_length(name) BETWEEN 1 AND 120),
    CONSTRAINT categories_version_chk CHECK (version >= 1),
    CONSTRAINT categories_id_family_key UNIQUE (id, family_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_categories_family_name_active
    ON categories (family_id, lower(name))
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_categories_family_active
    ON categories (family_id, deleted_at, sort_order, name);

CREATE TABLE IF NOT EXISTS products (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    name                TEXT NOT NULL,
    barcode             TEXT,
    brand               TEXT,
    specification       TEXT,
    category_id         UUID,
    identity_key        TEXT,
    notes               TEXT,
    created_by_user_id   UUID,
    updated_by_device   UUID,
    version             BIGINT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT products_category_fk
        FOREIGN KEY (category_id, family_id)
        REFERENCES categories (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT products_creator_fk
        FOREIGN KEY (family_id, created_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT products_updated_device_fk
        FOREIGN KEY (updated_by_device, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT products_name_length_chk CHECK (char_length(name) BETWEEN 1 AND 255),
    CONSTRAINT products_version_chk CHECK (version >= 1),
    CONSTRAINT products_id_family_key UNIQUE (id, family_id)
);

-- Barcode and identity_key are intentionally not unique: matching records are
-- candidates and require explicit user confirmation before merging.
CREATE INDEX IF NOT EXISTS ix_products_family_barcode
    ON products (family_id, barcode)
    WHERE deleted_at IS NULL AND barcode IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_products_family_identity
    ON products (family_id, identity_key)
    WHERE deleted_at IS NULL AND identity_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS ix_products_family_active_name
    ON products (family_id, deleted_at, lower(name));

CREATE TABLE IF NOT EXISTS product_batches (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id                   UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    product_id                  UUID NOT NULL,
    produced_date               DATE,
    expiry_date                 DATE,
    date_source                 TEXT,
    date_precision              TEXT,
    quantity                    INTEGER NOT NULL DEFAULT 0,
    initial_quantity            INTEGER NOT NULL DEFAULT 0,
    unit                        TEXT NOT NULL DEFAULT 'piece',
    opened_date                 DATE,
    expiry_after_opening_days   INTEGER,
    status                      TEXT NOT NULL DEFAULT 'active',
    storage_location            TEXT,
    supplier                    TEXT,
    price                       NUMERIC(12, 2),
    created_by_user_id          UUID,
    updated_by_device           UUID,
    version                     BIGINT NOT NULL DEFAULT 1,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at                  TIMESTAMPTZ,
    CONSTRAINT product_batches_product_fk
        FOREIGN KEY (product_id, family_id)
        REFERENCES products (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT product_batches_creator_fk
        FOREIGN KEY (family_id, created_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT product_batches_updated_device_fk
        FOREIGN KEY (updated_by_device, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT product_batches_quantity_chk CHECK (quantity >= 0),
    CONSTRAINT product_batches_initial_quantity_chk CHECK (initial_quantity >= 0),
    CONSTRAINT product_batches_opening_days_chk
        CHECK (expiry_after_opening_days IS NULL OR expiry_after_opening_days >= 0),
    CONSTRAINT product_batches_price_chk CHECK (price IS NULL OR price >= 0),
    CONSTRAINT product_batches_status_chk CHECK (status IN ('active', 'used_up', 'expired', 'discarded')),
    CONSTRAINT product_batches_date_precision_chk
        CHECK (date_precision IS NULL OR date_precision IN ('day', 'month', 'year', 'unknown')),
    CONSTRAINT product_batches_date_source_chk
        CHECK (date_source IS NULL OR date_source IN ('manual', 'barcode', 'ocr', 'ai_draft', 'import', 'sync')),
    CONSTRAINT product_batches_version_chk CHECK (version >= 1),
    CONSTRAINT product_batches_id_family_key UNIQUE (id, family_id)
);

CREATE INDEX IF NOT EXISTS ix_product_batches_family_product_active
    ON product_batches (family_id, product_id, deleted_at, status);
CREATE INDEX IF NOT EXISTS ix_product_batches_fefo
    ON product_batches (family_id, product_id, expiry_date, id)
    WHERE deleted_at IS NULL AND status = 'active' AND quantity > 0;

CREATE TABLE IF NOT EXISTS consumption_records (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    batch_id            UUID NOT NULL,
    product_id          UUID NOT NULL,
    record_type         TEXT NOT NULL,
    quantity_change     INTEGER NOT NULL,
    reason              TEXT,
    operation_id        UUID,
    idempotency_key     TEXT NOT NULL,
    created_by_user_id   UUID NOT NULL,
    device_id           UUID NOT NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT consumption_records_batch_fk
        FOREIGN KEY (batch_id, family_id)
        REFERENCES product_batches (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT consumption_records_product_fk
        FOREIGN KEY (product_id, family_id)
        REFERENCES products (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT consumption_records_creator_fk
        FOREIGN KEY (family_id, created_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT consumption_records_device_fk
        FOREIGN KEY (device_id, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT consumption_records_type_chk CHECK (record_type IN ('consume', 'restock', 'discard', 'adjust')),
    CONSTRAINT consumption_records_quantity_chk CHECK (
        (record_type IN ('consume', 'discard') AND quantity_change < 0)
        OR (record_type = 'restock' AND quantity_change > 0)
        OR (record_type = 'adjust' AND quantity_change <> 0)
    ),
    CONSTRAINT consumption_records_idempotency_length_chk CHECK (char_length(idempotency_key) BETWEEN 16 AND 255),
    CONSTRAINT consumption_records_family_idempotency_key UNIQUE (family_id, device_id, idempotency_key)
);

CREATE INDEX IF NOT EXISTS ix_consumption_records_family_created
    ON consumption_records (family_id, created_at DESC, id);
CREATE INDEX IF NOT EXISTS ix_consumption_records_batch_created
    ON consumption_records (family_id, batch_id, created_at DESC);

CREATE TABLE IF NOT EXISTS shopping_items (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    product_id          UUID,
    name                TEXT NOT NULL,
    desired_quantity    INTEGER NOT NULL DEFAULT 1,
    checked             BOOLEAN NOT NULL DEFAULT FALSE,
    checked_at          TIMESTAMPTZ,
    notes               TEXT,
    created_by_user_id   UUID,
    updated_by_device   UUID,
    version             BIGINT NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT shopping_items_product_fk
        FOREIGN KEY (product_id, family_id)
        REFERENCES products (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT shopping_items_creator_fk
        FOREIGN KEY (family_id, created_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT shopping_items_updated_device_fk
        FOREIGN KEY (updated_by_device, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT shopping_items_name_length_chk CHECK (char_length(name) BETWEEN 1 AND 255),
    CONSTRAINT shopping_items_quantity_chk CHECK (desired_quantity > 0),
    CONSTRAINT shopping_items_version_chk CHECK (version >= 1),
    CONSTRAINT shopping_items_id_family_key UNIQUE (id, family_id)
);

CREATE INDEX IF NOT EXISTS ix_shopping_items_family_active
    ON shopping_items (family_id, deleted_at, checked, created_at DESC);

CREATE TABLE IF NOT EXISTS reminder_settings (
    id                          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id                   UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    product_id                  UUID,
    enabled                     BOOLEAN NOT NULL DEFAULT TRUE,
    expiry_warning_days         INTEGER NOT NULL DEFAULT 7,
    low_stock_threshold         INTEGER,
    opened_warning_days         INTEGER,
    created_by_user_id          UUID,
    updated_by_device           UUID,
    version                     BIGINT NOT NULL DEFAULT 1,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at                  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at                  TIMESTAMPTZ,
    CONSTRAINT reminder_settings_product_fk
        FOREIGN KEY (product_id, family_id)
        REFERENCES products (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT reminder_settings_creator_fk
        FOREIGN KEY (family_id, created_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT reminder_settings_updated_device_fk
        FOREIGN KEY (updated_by_device, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT reminder_settings_expiry_days_chk CHECK (expiry_warning_days >= 0),
    CONSTRAINT reminder_settings_low_stock_chk CHECK (low_stock_threshold IS NULL OR low_stock_threshold > 0),
    CONSTRAINT reminder_settings_opened_days_chk CHECK (opened_warning_days IS NULL OR opened_warning_days >= 0),
    CONSTRAINT reminder_settings_version_chk CHECK (version >= 1),
    CONSTRAINT reminder_settings_id_family_key UNIQUE (id, family_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_reminder_settings_family_default_active
    ON reminder_settings (family_id)
    WHERE product_id IS NULL AND deleted_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS ux_reminder_settings_family_product_active
    ON reminder_settings (family_id, product_id)
    WHERE product_id IS NOT NULL AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_reminder_settings_family_active
    ON reminder_settings (family_id, deleted_at, enabled);

-- -------------------------------------------------------------------------
-- Sync cursor, conflict, and idempotency records
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS change_log (
    cursor              BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    change_id           UUID NOT NULL DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    operation           TEXT NOT NULL,
    entity              TEXT NOT NULL,
    entity_id           UUID NOT NULL,
    version             BIGINT,
    payload             JSONB NOT NULL DEFAULT '{}'::JSONB,
    updated_by_device   UUID,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT change_log_change_id_key UNIQUE (change_id),
    CONSTRAINT change_log_operation_chk CHECK (operation IN ('entity_upsert', 'entity_delete', 'inventory_command')),
    CONSTRAINT change_log_version_chk CHECK (version IS NULL OR version >= 1),
    CONSTRAINT change_log_payload_object_chk CHECK (jsonb_typeof(payload) = 'object'),
    CONSTRAINT change_log_updated_device_fk
        FOREIGN KEY (updated_by_device, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT
);

CREATE INDEX IF NOT EXISTS ix_change_log_family_cursor
    ON change_log (family_id, cursor);
CREATE INDEX IF NOT EXISTS ix_change_log_family_entity
    ON change_log (family_id, entity, entity_id, cursor);

CREATE TABLE IF NOT EXISTS conflict_records (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    change_id           UUID,
    device_id           UUID,
    entity              TEXT NOT NULL,
    entity_id           UUID NOT NULL,
    reason              TEXT NOT NULL,
    server_version      BIGINT,
    client_version      BIGINT,
    server_payload      JSONB NOT NULL DEFAULT '{}'::JSONB,
    client_payload      JSONB NOT NULL DEFAULT '{}'::JSONB,
    status              TEXT NOT NULL DEFAULT 'open',
    resolution          JSONB,
    resolved_by_user_id  UUID,
    resolved_at         TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT conflict_records_change_fk
        FOREIGN KEY (change_id) REFERENCES change_log(change_id) ON DELETE SET NULL,
    CONSTRAINT conflict_records_device_fk
        FOREIGN KEY (device_id, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT conflict_records_resolver_fk
        FOREIGN KEY (family_id, resolved_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT conflict_records_reason_chk
        CHECK (reason IN ('VERSION_CONFLICT', 'FAMILY_SCOPE_VIOLATION', 'COMMAND_REJECTED')),
    CONSTRAINT conflict_records_status_chk CHECK (status IN ('open', 'resolved', 'rejected')),
    CONSTRAINT conflict_records_server_version_chk CHECK (server_version IS NULL OR server_version >= 1),
    CONSTRAINT conflict_records_client_version_chk CHECK (client_version IS NULL OR client_version >= 0),
    CONSTRAINT conflict_records_server_payload_chk CHECK (jsonb_typeof(server_payload) = 'object'),
    CONSTRAINT conflict_records_client_payload_chk CHECK (jsonb_typeof(client_payload) = 'object')
);

CREATE INDEX IF NOT EXISTS ix_conflict_records_family_status
    ON conflict_records (family_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_conflict_records_family_entity
    ON conflict_records (family_id, entity, entity_id, created_at DESC);

CREATE TABLE IF NOT EXISTS sync_idempotency (
    idempotency_key     TEXT NOT NULL,
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    device_id           UUID NOT NULL,
    operation           TEXT NOT NULL,
    entity              TEXT,
    entity_id           UUID,
    status              TEXT NOT NULL,
    response_payload    JSONB NOT NULL DEFAULT '{}'::JSONB,
    server_cursor       BIGINT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    completed_at        TIMESTAMPTZ,
    expires_at          TIMESTAMPTZ,
    PRIMARY KEY (family_id, device_id, idempotency_key),
    CONSTRAINT sync_idempotency_device_fk
        FOREIGN KEY (device_id, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT sync_idempotency_key_length_chk CHECK (char_length(idempotency_key) BETWEEN 16 AND 255),
    CONSTRAINT sync_idempotency_status_chk CHECK (status IN ('processing', 'accepted', 'conflict', 'rejected')),
    CONSTRAINT sync_idempotency_operation_chk CHECK (operation IN ('entity_upsert', 'entity_delete', 'inventory_command', 'home_assistant_command')),
    CONSTRAINT sync_idempotency_payload_chk CHECK (jsonb_typeof(response_payload) = 'object'),
    CONSTRAINT sync_idempotency_cursor_chk CHECK (server_cursor IS NULL OR server_cursor >= 1),
    CONSTRAINT sync_idempotency_expiry_chk CHECK (expires_at IS NULL OR expires_at >= created_at)
);

CREATE INDEX IF NOT EXISTS ix_sync_idempotency_expiry
    ON sync_idempotency (expires_at)
    WHERE expires_at IS NOT NULL;

-- -------------------------------------------------------------------------
-- Home Assistant state, permissions, and audit
-- -------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS ha_integrations (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id                UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    name                     TEXT NOT NULL,
    base_url                 TEXT NOT NULL,
    access_token_ciphertext  BYTEA NOT NULL,
    key_version              INTEGER NOT NULL DEFAULT 1,
    enabled                  BOOLEAN NOT NULL DEFAULT TRUE,
    status                   TEXT NOT NULL DEFAULT 'unknown',
    last_checked_at          TIMESTAMPTZ,
    created_by_user_id       UUID NOT NULL,
    updated_by_user_id       UUID,
    created_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at               TIMESTAMPTZ,
    CONSTRAINT ha_integrations_creator_fk
        FOREIGN KEY (family_id, created_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_integrations_updater_fk
        FOREIGN KEY (family_id, updated_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_integrations_name_length_chk CHECK (char_length(name) BETWEEN 1 AND 120),
    CONSTRAINT ha_integrations_base_url_chk CHECK (base_url ~* '^https?://'),
    CONSTRAINT ha_integrations_key_version_chk CHECK (key_version >= 1),
    CONSTRAINT ha_integrations_status_chk CHECK (status IN ('unknown', 'healthy', 'unavailable', 'invalid_credentials', 'disabled')),
    CONSTRAINT ha_integrations_id_family_key UNIQUE (id, family_id)
);

COMMENT ON COLUMN ha_integrations.access_token_ciphertext IS 'Application-encrypted Home Assistant token; plaintext token and Authorization header must never be stored or logged.';
CREATE UNIQUE INDEX IF NOT EXISTS ux_ha_integrations_family_name_active
    ON ha_integrations (family_id, lower(name))
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ha_integrations_family_status
    ON ha_integrations (family_id, deleted_at, enabled, status);

CREATE TABLE IF NOT EXISTS ha_devices (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    integration_id      UUID NOT NULL,
    ha_device_id        TEXT NOT NULL,
    name                TEXT NOT NULL,
    manufacturer        TEXT,
    model               TEXT,
    area_name           TEXT,
    metadata            JSONB NOT NULL DEFAULT '{}'::JSONB,
    last_seen_at        TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT ha_devices_integration_fk
        FOREIGN KEY (integration_id, family_id)
        REFERENCES ha_integrations (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_devices_name_length_chk CHECK (char_length(name) BETWEEN 1 AND 255),
    CONSTRAINT ha_devices_metadata_chk CHECK (jsonb_typeof(metadata) = 'object'),
    CONSTRAINT ha_devices_id_family_key UNIQUE (id, family_id),
    CONSTRAINT ha_devices_integration_device_key UNIQUE (integration_id, ha_device_id)
);

CREATE INDEX IF NOT EXISTS ix_ha_devices_family_integration_active
    ON ha_devices (family_id, integration_id, deleted_at, name);

CREATE TABLE IF NOT EXISTS ha_entities (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    integration_id      UUID NOT NULL,
    ha_device_id        UUID,
    entity_id           TEXT NOT NULL,
    domain              TEXT NOT NULL,
    name                TEXT NOT NULL,
    area_name           TEXT,
    capabilities        JSONB NOT NULL DEFAULT '[]'::JSONB,
    current_state       TEXT,
    current_attributes  JSONB NOT NULL DEFAULT '{}'::JSONB,
    is_visible          BOOLEAN NOT NULL DEFAULT TRUE,
    is_controllable     BOOLEAN NOT NULL DEFAULT FALSE,
    last_state_at       TIMESTAMPTZ,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT ha_entities_integration_fk
        FOREIGN KEY (integration_id, family_id)
        REFERENCES ha_integrations (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_entities_device_fk
        FOREIGN KEY (ha_device_id, family_id)
        REFERENCES ha_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_entities_entity_id_chk CHECK (char_length(entity_id) BETWEEN 1 AND 255),
    CONSTRAINT ha_entities_domain_chk CHECK (char_length(domain) BETWEEN 1 AND 64),
    CONSTRAINT ha_entities_name_length_chk CHECK (char_length(name) BETWEEN 1 AND 255),
    CONSTRAINT ha_entities_capabilities_chk CHECK (jsonb_typeof(capabilities) = 'array'),
    CONSTRAINT ha_entities_attributes_chk CHECK (jsonb_typeof(current_attributes) = 'object'),
    CONSTRAINT ha_entities_id_family_key UNIQUE (id, family_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_ha_entities_integration_entity_active
    ON ha_entities (integration_id, entity_id)
    WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS ix_ha_entities_family_visible
    ON ha_entities (family_id, integration_id, deleted_at, is_visible);

CREATE TABLE IF NOT EXISTS ha_entity_permissions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id           UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    entity_id           UUID NOT NULL,
    role                TEXT NOT NULL,
    can_view            BOOLEAN NOT NULL DEFAULT FALSE,
    can_control         BOOLEAN NOT NULL DEFAULT FALSE,
    allowed_commands    TEXT[] NOT NULL DEFAULT ARRAY[]::TEXT[],
    created_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at          TIMESTAMPTZ,
    CONSTRAINT ha_entity_permissions_entity_fk
        FOREIGN KEY (entity_id, family_id)
        REFERENCES ha_entities (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_entity_permissions_role_chk CHECK (role IN ('owner', 'admin', 'member')),
    CONSTRAINT ha_entity_permissions_commands_chk CHECK (
        can_control OR cardinality(allowed_commands) = 0
    ),
    CONSTRAINT ha_entity_permissions_entity_role_key UNIQUE (entity_id, role)
);

CREATE INDEX IF NOT EXISTS ix_ha_entity_permissions_family_role
    ON ha_entity_permissions (family_id, role, deleted_at, entity_id);

CREATE TABLE IF NOT EXISTS ha_command_logs (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id             UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    integration_id        UUID NOT NULL,
    entity_id             UUID,
    requested_by_user_id  UUID NOT NULL,
    device_id             UUID,
    request_id            UUID NOT NULL,
    command               TEXT NOT NULL,
    safe_parameters_summary JSONB NOT NULL DEFAULT '{}'::JSONB,
    result                TEXT NOT NULL,
    error_code            TEXT,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ha_command_logs_integration_fk
        FOREIGN KEY (integration_id, family_id)
        REFERENCES ha_integrations (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_command_logs_entity_fk
        FOREIGN KEY (entity_id, family_id)
        REFERENCES ha_entities (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_command_logs_requester_fk
        FOREIGN KEY (family_id, requested_by_user_id)
        REFERENCES family_members (family_id, user_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_command_logs_device_fk
        FOREIGN KEY (device_id, family_id)
        REFERENCES sync_devices (id, family_id)
        ON DELETE RESTRICT,
    CONSTRAINT ha_command_logs_command_chk CHECK (
        command IN ('turn_on', 'turn_off', 'toggle', 'set_brightness', 'set_temperature',
                    'set_hvac_mode', 'play', 'pause', 'activate_scene', 'run_script')
    ),
    CONSTRAINT ha_command_logs_parameters_chk CHECK (jsonb_typeof(safe_parameters_summary) = 'object'),
    CONSTRAINT ha_command_logs_result_chk CHECK (result IN ('accepted', 'succeeded', 'failed', 'rejected')),
    CONSTRAINT ha_command_logs_request_key UNIQUE (family_id, request_id)
);

CREATE INDEX IF NOT EXISTS ix_ha_command_logs_family_created
    ON ha_command_logs (family_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_ha_command_logs_entity_created
    ON ha_command_logs (family_id, entity_id, created_at DESC);

-- All mutable family-scoped entities use the same UTC updated_at trigger.
DO $$
DECLARE
    table_name TEXT;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'families', 'family_members', 'sync_devices', 'family_invites',
        'categories', 'products', 'product_batches', 'shopping_items',
        'reminder_settings', 'ha_integrations', 'ha_devices', 'ha_entities',
        'ha_entity_permissions'
    ] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', 'trg_' || table_name || '_updated_at', table_name);
        EXECUTE format(
            'CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION momo_set_updated_at()',
            'trg_' || table_name || '_updated_at', table_name
        );
    END LOOP;
END;
$$;

-- Record the schema version only after every DDL statement above succeeds.
-- The checksum value is the immutable migration identity used by the SQL-only
-- bootstrap. A future migration must use a new version instead of rewriting
-- this file.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM schema_migrations
        WHERE version = 1
          AND name = '0001_initial_schema.sql'
          AND checksum = 'sha256:0001-initial-schema-v1'
    ) THEN
        NULL;
    ELSIF EXISTS (SELECT 1 FROM schema_migrations WHERE version = 1) THEN
        RAISE EXCEPTION
            'schema migration version 1 is already recorded with a different name or checksum';
    ELSE
        INSERT INTO schema_migrations (version, name, checksum)
        VALUES (1, '0001_initial_schema.sql', 'sha256:0001-initial-schema-v1');
    END IF;
END;
$$;

COMMIT;
