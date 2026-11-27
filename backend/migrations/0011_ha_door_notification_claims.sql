BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('momobox:postgres:migrations', 0));
SET LOCAL search_path = public;

CREATE TABLE ha_door_notification_claims (
    family_id UUID NOT NULL,
    integration_id UUID NOT NULL,
    entity_id TEXT NOT NULL,
    occurred_at TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (integration_id, entity_id, occurred_at),
    FOREIGN KEY (integration_id, family_id)
        REFERENCES ha_integrations (id, family_id) ON DELETE CASCADE
);

COMMIT;
