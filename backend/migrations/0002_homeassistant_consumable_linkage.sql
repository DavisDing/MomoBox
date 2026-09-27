-- MomoBox Home Assistant consumable linkage.
-- This migration is additive and keeps the feature independent from the sync
-- core. Rows have stable IDs/statuses so a future sync adapter can publish
-- them as family-scoped changes without replaying inventory mutations.
BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL TIME ZONE 'UTC';
SET LOCAL search_path = public;

CREATE TABLE IF NOT EXISTS ha_consumable_groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ,
    CONSTRAINT ha_consumable_groups_name_chk CHECK (char_length(name) BETWEEN 1 AND 120),
    CONSTRAINT ha_consumable_groups_id_family_key UNIQUE (id, family_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_ha_consumable_groups_family_name
    ON ha_consumable_groups (family_id, lower(name)) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS ha_consumable_group_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL,
    group_id UUID NOT NULL,
    product_id UUID NOT NULL,
    quantity INTEGER NOT NULL,
    unit TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ha_consumable_group_items_group_fk
        FOREIGN KEY (group_id, family_id) REFERENCES ha_consumable_groups(id, family_id) ON DELETE CASCADE,
    CONSTRAINT ha_consumable_group_items_product_fk
        FOREIGN KEY (product_id, family_id) REFERENCES products(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_consumable_group_items_quantity_chk CHECK (quantity > 0),
    CONSTRAINT ha_consumable_group_items_unit_chk CHECK (unit IN ('piece', 'capsule', 'tablet', 'load', 'cycle')),
    CONSTRAINT ha_consumable_group_items_unique UNIQUE (group_id, product_id)
);

CREATE TABLE IF NOT EXISTS ha_consumable_recipes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ,
    CONSTRAINT ha_consumable_recipes_name_chk CHECK (char_length(name) BETWEEN 1 AND 120),
    CONSTRAINT ha_consumable_recipes_id_family_key UNIQUE (id, family_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_ha_consumable_recipes_family_name
    ON ha_consumable_recipes (family_id, lower(name)) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS ha_consumable_recipe_groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL,
    recipe_id UUID NOT NULL,
    group_id UUID NOT NULL,
    quantity INTEGER NOT NULL,
    unit TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ha_consumable_recipe_groups_recipe_fk
        FOREIGN KEY (recipe_id, family_id) REFERENCES ha_consumable_recipes(id, family_id) ON DELETE CASCADE,
    CONSTRAINT ha_consumable_recipe_groups_group_fk
        FOREIGN KEY (group_id, family_id) REFERENCES ha_consumable_groups(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_consumable_recipe_groups_quantity_chk CHECK (quantity > 0),
    CONSTRAINT ha_consumable_recipe_groups_unit_chk CHECK (unit IN ('piece', 'capsule', 'tablet', 'load', 'cycle')),
    CONSTRAINT ha_consumable_recipe_groups_unique UNIQUE (recipe_id, group_id)
);

CREATE TABLE IF NOT EXISTS ha_linkage_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    name TEXT NOT NULL,
    integration_id UUID NOT NULL,
    entity_id UUID NOT NULL,
    appliance_domain TEXT NOT NULL,
    start_state TEXT NOT NULL,
    complete_state TEXT NOT NULL,
    recipe_id UUID NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    requires_confirmation BOOLEAN NOT NULL DEFAULT TRUE,
    created_by_user_id UUID NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    deleted_at TIMESTAMPTZ,
    CONSTRAINT ha_linkage_rules_name_chk CHECK (char_length(name) BETWEEN 1 AND 120),
    CONSTRAINT ha_linkage_rules_confirmation_chk CHECK (requires_confirmation = TRUE),
    CONSTRAINT ha_linkage_rules_integration_fk
        FOREIGN KEY (integration_id, family_id) REFERENCES ha_integrations(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_linkage_rules_entity_fk
        FOREIGN KEY (entity_id, family_id) REFERENCES ha_entities(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_linkage_rules_recipe_fk
        FOREIGN KEY (recipe_id, family_id) REFERENCES ha_consumable_recipes(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_linkage_rules_id_family_key UNIQUE (id, family_id)
);
CREATE INDEX IF NOT EXISTS ix_ha_linkage_rules_entity
    ON ha_linkage_rules (family_id, entity_id, enabled) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS ha_appliance_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    rule_id UUID NOT NULL,
    appliance_run_id TEXT NOT NULL,
    integration_id UUID NOT NULL,
    entity_id UUID NOT NULL,
    domain TEXT NOT NULL,
    status TEXT NOT NULL,
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ha_appliance_runs_rule_fk FOREIGN KEY (rule_id, family_id) REFERENCES ha_linkage_rules(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_appliance_runs_status_chk CHECK (status IN ('running', 'completed', 'ignored')),
    CONSTRAINT ha_appliance_runs_idempotency_key UNIQUE (family_id, rule_id, appliance_run_id)
);

CREATE TABLE IF NOT EXISTS ha_linkage_suggestions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    rule_id UUID NOT NULL,
    recipe_id UUID NOT NULL,
    appliance_run_id TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    requires_confirmation BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    resolved_at TIMESTAMPTZ,
    resolved_by_user_id UUID REFERENCES users(id) ON DELETE RESTRICT,
    CONSTRAINT ha_linkage_suggestions_rule_fk FOREIGN KEY (rule_id, family_id) REFERENCES ha_linkage_rules(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_linkage_suggestions_recipe_fk FOREIGN KEY (recipe_id, family_id) REFERENCES ha_consumable_recipes(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_linkage_suggestions_status_chk CHECK (status IN ('pending', 'deducted', 'ignored', 'insufficient_stock')),
    CONSTRAINT ha_linkage_suggestions_confirmation_chk CHECK (requires_confirmation = TRUE),
    CONSTRAINT ha_linkage_suggestions_idempotency_key UNIQUE (family_id, rule_id, appliance_run_id)
);
CREATE INDEX IF NOT EXISTS ix_ha_linkage_suggestions_family_status
    ON ha_linkage_suggestions (family_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS ha_linkage_purchase_suggestions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    suggestion_id UUID NOT NULL REFERENCES ha_linkage_suggestions(id) ON DELETE CASCADE,
    product_id UUID NOT NULL,
    quantity INTEGER NOT NULL,
    unit TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ha_linkage_purchase_suggestions_product_fk FOREIGN KEY (product_id, family_id) REFERENCES products(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_linkage_purchase_suggestions_quantity_chk CHECK (quantity > 0),
    CONSTRAINT ha_linkage_purchase_suggestions_unit_chk CHECK (unit IN ('piece', 'capsule', 'tablet', 'load', 'cycle')),
    CONSTRAINT ha_linkage_purchase_suggestions_unique UNIQUE (suggestion_id, product_id)
);

CREATE TABLE IF NOT EXISTS ha_linkage_deductions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    suggestion_id UUID NOT NULL REFERENCES ha_linkage_suggestions(id) ON DELETE RESTRICT,
    product_id UUID NOT NULL,
    batch_id UUID NOT NULL,
    quantity INTEGER NOT NULL,
    before_quantity INTEGER NOT NULL,
    after_quantity INTEGER NOT NULL,
    before_version BIGINT NOT NULL,
    after_version BIGINT NOT NULL,
    operation_id UUID NOT NULL,
    sync_contract TEXT NOT NULL DEFAULT 'ha_linkage_inventory_v1',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ha_linkage_deductions_product_fk FOREIGN KEY (product_id, family_id) REFERENCES products(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_linkage_deductions_batch_fk FOREIGN KEY (batch_id, family_id) REFERENCES product_batches(id, family_id) ON DELETE RESTRICT,
    CONSTRAINT ha_linkage_deductions_quantity_chk CHECK (quantity > 0 AND after_quantity >= 0),
    CONSTRAINT ha_linkage_deductions_unique UNIQUE (suggestion_id, batch_id)
);

CREATE TABLE IF NOT EXISTS ha_linkage_audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    family_id UUID NOT NULL REFERENCES families(id) ON DELETE RESTRICT,
    rule_id UUID,
    appliance_run_id TEXT,
    suggestion_id UUID,
    action TEXT NOT NULL,
    actor_id UUID REFERENCES users(id) ON DELETE RESTRICT,
    details JSONB NOT NULL DEFAULT '{}'::JSONB,
    sync_contract TEXT NOT NULL DEFAULT 'ha_linkage_event_v1',
    created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ha_linkage_audit_logs_details_chk CHECK (jsonb_typeof(details) = 'object')
);
CREATE INDEX IF NOT EXISTS ix_ha_linkage_audit_family_created
    ON ha_linkage_audit_logs (family_id, created_at DESC);

DO $$
DECLARE table_name TEXT;
BEGIN
    FOREACH table_name IN ARRAY ARRAY[
        'ha_consumable_groups', 'ha_consumable_group_items', 'ha_consumable_recipes',
        'ha_consumable_recipe_groups', 'ha_linkage_rules', 'ha_appliance_runs'
    ] LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I', 'trg_' || table_name || '_updated_at', table_name);
        IF table_name NOT IN ('ha_consumable_group_items', 'ha_consumable_recipe_groups') THEN
            EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE ON %I FOR EACH ROW EXECUTE FUNCTION momo_set_updated_at()', 'trg_' || table_name || '_updated_at', table_name);
        END IF;
    END LOOP;
END;
$$;

-- The Go migration runner records the exact file checksum in schema_migrations.

COMMIT;
