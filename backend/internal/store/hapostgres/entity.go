package hapostgres

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/momobox/backend/internal/homeassistant"
)

type EntityRepository struct {
	db DB
}

func NewEntityRepository(db DB) *EntityRepository {
	return &EntityRepository{db: db}
}

var _ homeassistant.EntityRepository = (*EntityRepository)(nil)

type persistedEntityAttributes struct {
	HVACModes      []string `json:"hvac_modes,omitempty"`
	TemperatureMin *float64 `json:"temperature_min,omitempty"`
	TemperatureMax *float64 `json:"temperature_max,omitempty"`
}

func (r *EntityRepository) ReplaceForIntegration(ctx context.Context, familyID, integrationID string, entities []homeassistant.HAEntity) error {
	if err := requireDB(r.db); err != nil {
		return err
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin Home Assistant entity replacement: %w", err)
	}
	defer rollback(tx)

	seen := make([]string, 0, len(entities))
	for _, entity := range entities {
		seen = append(seen, entity.EntityID)
		if err := upsertEntity(ctx, tx, familyID, integrationID, entity); err != nil {
			return err
		}
	}
	seenJSON, err := marshalJSON(seen)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
UPDATE ha_entities AS e
SET deleted_at = CURRENT_TIMESTAMP,
    is_visible = FALSE,
    is_controllable = FALSE,
    updated_at = CURRENT_TIMESTAMP
WHERE e.family_id = $1
  AND e.integration_id = $2
  AND e.deleted_at IS NULL
  AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text($3::jsonb) AS incoming(entity_id)
      WHERE incoming.entity_id = e.entity_id
  )`, familyID, integrationID, seenJSON)
	if err != nil {
		return fmt.Errorf("soft-delete missing Home Assistant entities: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit Home Assistant entity replacement: %w", err)
	}
	return nil
}

func upsertEntity(ctx context.Context, tx *sql.Tx, familyID, integrationID string, entity homeassistant.HAEntity) error {
	if entity.DeviceID != "" {
		var exists bool
		err := tx.QueryRowContext(ctx, `
SELECT EXISTS (
    SELECT 1
    FROM ha_devices
    WHERE id = $1 AND family_id = $2 AND integration_id = $3 AND deleted_at IS NULL
)`, entity.DeviceID, familyID, integrationID).Scan(&exists)
		if err != nil {
			return fmt.Errorf("validate Home Assistant entity device: %w", err)
		}
		if !exists {
			return notFound("Home Assistant device", sql.ErrNoRows)
		}
	}
	capabilities, err := marshalJSON(entity.Capabilities)
	if err != nil {
		return err
	}
	attributes, err := marshalJSON(persistedEntityAttributes{
		HVACModes:      entity.HVACModes,
		TemperatureMin: entity.TemperatureMin,
		TemperatureMax: entity.TemperatureMax,
	})
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
INSERT INTO ha_entities (
    id, family_id, integration_id, ha_device_id, entity_id, domain, name,
    area_name, capabilities, current_state, current_attributes, is_visible,
    is_controllable, last_state_at, created_at, updated_at, deleted_at
) VALUES (
    $1, $2, $3, $4, $5, $6, $7,
    $8, $9::jsonb, $10, $11::jsonb, $12,
    $13, $14, $15, $16, NULL
)
ON CONFLICT (integration_id, entity_id) WHERE deleted_at IS NULL
DO UPDATE SET
    ha_device_id = EXCLUDED.ha_device_id,
    domain = EXCLUDED.domain,
    name = EXCLUDED.name,
    area_name = EXCLUDED.area_name,
    capabilities = EXCLUDED.capabilities,
    current_state = EXCLUDED.current_state,
    current_attributes = EXCLUDED.current_attributes,
    is_visible = EXCLUDED.is_visible,
    is_controllable = EXCLUDED.is_controllable,
    last_state_at = EXCLUDED.last_state_at,
    updated_at = EXCLUDED.updated_at,
    deleted_at = NULL`,
		entity.ID,
		familyID,
		integrationID,
		nullableText(entity.DeviceID),
		entity.EntityID,
		entity.Domain,
		entity.Name,
		nullableText(entity.AreaName),
		capabilities,
		nullableText(entity.CurrentState),
		attributes,
		entity.IsVisible,
		entity.IsControllable,
		entity.LastStateAt,
		entity.CreatedAt,
		entity.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("upsert Home Assistant entity: %w", err)
	}
	return nil
}

func (r *EntityRepository) Get(ctx context.Context, familyID, integrationID, entityID string) (homeassistant.HAEntity, error) {
	if err := requireDB(r.db); err != nil {
		return homeassistant.HAEntity{}, err
	}
	entity, err := scanEntity(r.db.QueryRowContext(ctx, entitySelect+`
WHERE family_id = $1
  AND integration_id = $2
  AND entity_id = $3
  AND deleted_at IS NULL`, familyID, integrationID, entityID))
	if errors.Is(err, sql.ErrNoRows) {
		return homeassistant.HAEntity{}, notFound("Home Assistant entity", err)
	}
	if err != nil {
		return homeassistant.HAEntity{}, fmt.Errorf("get Home Assistant entity: %w", err)
	}
	return entity, nil
}

func (r *EntityRepository) List(ctx context.Context, familyID, integrationID string) ([]homeassistant.HAEntity, error) {
	if err := requireDB(r.db); err != nil {
		return nil, err
	}
	query := entitySelect + `
WHERE family_id = $1 AND deleted_at IS NULL`
	args := []any{familyID}
	if integrationID != "" {
		query += ` AND integration_id = $2`
		args = append(args, integrationID)
	}
	query += ` ORDER BY lower(name), entity_id`
	rows, err := r.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list Home Assistant entities: %w", err)
	}
	defer rows.Close()

	result := make([]homeassistant.HAEntity, 0)
	for rows.Next() {
		entity, scanErr := scanEntity(rows)
		if scanErr != nil {
			return nil, fmt.Errorf("scan Home Assistant entity: %w", scanErr)
		}
		result = append(result, entity)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate Home Assistant entities: %w", err)
	}
	return result, nil
}

const entitySelect = `
SELECT id::text, family_id::text, integration_id::text, COALESCE(ha_device_id::text, ''),
       entity_id, domain, name, COALESCE(area_name, ''), capabilities,
       COALESCE(current_state, ''), current_attributes, is_visible,
       is_controllable, last_state_at, created_at, updated_at
FROM ha_entities
`

func scanEntity(row scanner) (homeassistant.HAEntity, error) {
	var entity homeassistant.HAEntity
	var capabilitiesJSON []byte
	var attributesJSON []byte
	err := row.Scan(
		&entity.ID,
		&entity.FamilyID,
		&entity.IntegrationID,
		&entity.DeviceID,
		&entity.EntityID,
		&entity.Domain,
		&entity.Name,
		&entity.AreaName,
		&capabilitiesJSON,
		&entity.CurrentState,
		&attributesJSON,
		&entity.IsVisible,
		&entity.IsControllable,
		&entity.LastStateAt,
		&entity.CreatedAt,
		&entity.UpdatedAt,
	)
	if err != nil {
		return homeassistant.HAEntity{}, err
	}
	if err := json.Unmarshal(capabilitiesJSON, &entity.Capabilities); err != nil {
		return homeassistant.HAEntity{}, fmt.Errorf("decode Home Assistant entity capabilities: %w", err)
	}
	var attributes persistedEntityAttributes
	if len(attributesJSON) > 0 {
		if err := json.Unmarshal(attributesJSON, &attributes); err != nil {
			return homeassistant.HAEntity{}, fmt.Errorf("decode Home Assistant entity attributes: %w", err)
		}
	}
	entity.HVACModes = attributes.HVACModes
	entity.TemperatureMin = attributes.TemperatureMin
	entity.TemperatureMax = attributes.TemperatureMax
	return entity, nil
}
