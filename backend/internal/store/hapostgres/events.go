package hapostgres

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/momobox/backend/internal/homeassistant"
)

type EventRepository struct {
	db DB
}

func NewEventRepository(db DB) *EventRepository {
	return &EventRepository{db: db}
}

func (r *EventRepository) ListEventTargets(ctx context.Context, doors []homeassistant.NightDoor) ([]homeassistant.EventTarget, error) {
	if doors == nil {
		doors = []homeassistant.NightDoor{}
	}
	config, err := json.Marshal(doors)
	if err != nil {
		return nil, err
	}
	rows, err := r.db.QueryContext(ctx, `
WITH doors AS (
    SELECT integration_id, entity_id
    FROM jsonb_to_recordset($1::jsonb)
         AS door(integration_id uuid, entity_id text)
)
SELECT i.family_id::text, i.id::text, e.entity_id, e.domain, e.name, f.time_zone,
       COALESCE(linkage.rule_id, '')
FROM ha_entities e
JOIN ha_integrations i ON i.id = e.integration_id AND i.family_id = e.family_id
JOIN families f ON f.id = i.family_id AND f.deleted_at IS NULL
LEFT JOIN doors d ON d.integration_id = i.id AND d.entity_id = e.entity_id AND e.domain = 'binary_sensor'
LEFT JOIN LATERAL (
    SELECT min(r.id::text) AS rule_id
    FROM ha_linkage_rules r
    JOIN ha_consumable_recipes recipe ON recipe.id = r.recipe_id AND recipe.family_id = r.family_id
    WHERE r.family_id = e.family_id AND r.integration_id = e.integration_id AND r.entity_id = e.id
      AND r.appliance_domain = e.domain AND r.enabled AND r.deleted_at IS NULL AND recipe.deleted_at IS NULL
      AND r.start_state = 'running' AND r.complete_state = 'completed'
    HAVING count(*) = 1
) linkage ON true
WHERE i.enabled AND i.deleted_at IS NULL AND e.deleted_at IS NULL
  AND (d.entity_id IS NOT NULL OR linkage.rule_id IS NOT NULL)
ORDER BY i.id, e.entity_id`, string(config))
	if err != nil {
		return nil, fmt.Errorf("list HA event targets: %w", err)
	}
	defer rows.Close()
	var targets []homeassistant.EventTarget
	for rows.Next() {
		var target homeassistant.EventTarget
		if err := rows.Scan(&target.FamilyID, &target.IntegrationID, &target.EntityID, &target.Domain,
			&target.Name, &target.TimeZone, &target.LinkageRuleID); err != nil {
			return nil, fmt.Errorf("read HA event target: %w", err)
		}
		targets = append(targets, target)
	}
	return targets, rows.Err()
}

func (r *EventRepository) ClaimDoorOpening(ctx context.Context, target homeassistant.EventTarget, occurredAt time.Time) (bool, error) {
	result, err := r.db.ExecContext(ctx, `
INSERT INTO ha_door_notification_claims (family_id, integration_id, entity_id, occurred_at)
SELECT e.family_id, i.id, e.entity_id, $4
FROM ha_entities e
JOIN ha_integrations i ON i.id = e.integration_id AND i.family_id = e.family_id
JOIN families f ON f.id = i.family_id AND f.deleted_at IS NULL
WHERE e.family_id = $1 AND e.integration_id = $2 AND e.entity_id = $3
  AND e.domain = 'binary_sensor' AND e.deleted_at IS NULL AND i.enabled AND i.deleted_at IS NULL
  AND f.time_zone = $5
ON CONFLICT (integration_id, entity_id, occurred_at) DO NOTHING`,
		target.FamilyID, target.IntegrationID, target.EntityID, occurredAt, target.TimeZone)
	if err != nil {
		return false, fmt.Errorf("claim HA door notification: %w", err)
	}
	count, err := result.RowsAffected()
	return count == 1, err
}
