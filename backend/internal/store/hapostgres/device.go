package hapostgres

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/momobox/backend/internal/homeassistant"
)

type DeviceRepository struct {
	db DB
}

func NewDeviceRepository(db DB) *DeviceRepository {
	return &DeviceRepository{db: db}
}

var _ homeassistant.DeviceRepository = (*DeviceRepository)(nil)

func (r *DeviceRepository) ReplaceForIntegration(ctx context.Context, familyID, integrationID string, devices []homeassistant.HADevice) error {
	if err := requireDB(r.db); err != nil {
		return err
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin Home Assistant device replacement: %w", err)
	}
	defer rollback(tx)

	seen := make([]string, 0, len(devices))
	for _, device := range devices {
		seen = append(seen, device.HADeviceID)
		if err := upsertDevice(ctx, tx, familyID, integrationID, device); err != nil {
			return err
		}
	}
	seenJSON, err := marshalJSON(seen)
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx, `
UPDATE ha_devices AS d
SET deleted_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE d.family_id = $1
  AND d.integration_id = $2
  AND d.deleted_at IS NULL
  AND NOT EXISTS (
      SELECT 1
      FROM jsonb_array_elements_text($3::jsonb) AS incoming(ha_device_id)
      WHERE incoming.ha_device_id = d.ha_device_id
  )`, familyID, integrationID, seenJSON)
	if err != nil {
		return fmt.Errorf("soft-delete missing Home Assistant devices: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit Home Assistant device replacement: %w", err)
	}
	return nil
}

func upsertDevice(ctx context.Context, tx *sql.Tx, familyID, integrationID string, device homeassistant.HADevice) error {
	var existingID string
	err := tx.QueryRowContext(ctx, `
SELECT id::text
FROM ha_devices
WHERE family_id = $1 AND integration_id = $2 AND ha_device_id = $3
FOR UPDATE`, familyID, integrationID, device.HADeviceID).Scan(&existingID)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("lock Home Assistant device: %w", err)
	}

	if errors.Is(err, sql.ErrNoRows) {
		_, insertErr := tx.ExecContext(ctx, `
INSERT INTO ha_devices (
    id, family_id, integration_id, ha_device_id, name, manufacturer, model,
    area_name, metadata, last_seen_at, created_at, updated_at, deleted_at
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, '{}'::jsonb, $9, $10, $11, NULL)`,
			device.ID,
			familyID,
			integrationID,
			device.HADeviceID,
			device.Name,
			nullableText(device.Manufacturer),
			nullableText(device.Model),
			nullableText(device.AreaName),
			device.UpdatedAt,
			device.CreatedAt,
			device.UpdatedAt,
		)
		if insertErr != nil {
			return fmt.Errorf("insert Home Assistant device: %w", insertErr)
		}
		return nil
	}

	// Discovery currently assigns fresh IDs. Detach child rows inside this
	// transaction before moving the device PK, then EntityRepository reconnects
	// them using the same incoming IDs. No sync_devices row is ever involved.
	if existingID != device.ID {
		if _, err := tx.ExecContext(ctx, `
UPDATE ha_entities
SET ha_device_id = NULL, updated_at = CURRENT_TIMESTAMP
WHERE family_id = $1 AND integration_id = $2 AND ha_device_id = $3`, familyID, integrationID, existingID); err != nil {
			return fmt.Errorf("detach Home Assistant entities from replaced device: %w", err)
		}
	}
	_, err = tx.ExecContext(ctx, `
UPDATE ha_devices
SET id = $4,
    name = $5,
    manufacturer = $6,
    model = $7,
    area_name = $8,
    last_seen_at = $9,
    updated_at = $10,
    deleted_at = NULL
WHERE family_id = $1 AND integration_id = $2 AND ha_device_id = $3`,
		familyID,
		integrationID,
		device.HADeviceID,
		device.ID,
		device.Name,
		nullableText(device.Manufacturer),
		nullableText(device.Model),
		nullableText(device.AreaName),
		device.UpdatedAt,
		device.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("update Home Assistant device: %w", err)
	}
	return nil
}

func (r *DeviceRepository) List(ctx context.Context, familyID, integrationID string) ([]homeassistant.HADevice, error) {
	if err := requireDB(r.db); err != nil {
		return nil, err
	}
	rows, err := r.db.QueryContext(ctx, `
SELECT id::text, family_id::text, integration_id::text, ha_device_id, name,
       COALESCE(area_name, ''), COALESCE(manufacturer, ''), COALESCE(model, ''),
       created_at, updated_at
FROM ha_devices
WHERE family_id = $1 AND integration_id = $2 AND deleted_at IS NULL
ORDER BY lower(name), id`, familyID, integrationID)
	if err != nil {
		return nil, fmt.Errorf("list Home Assistant devices: %w", err)
	}
	defer rows.Close()

	result := make([]homeassistant.HADevice, 0)
	for rows.Next() {
		var device homeassistant.HADevice
		if err := rows.Scan(
			&device.ID,
			&device.FamilyID,
			&device.IntegrationID,
			&device.HADeviceID,
			&device.Name,
			&device.AreaName,
			&device.Manufacturer,
			&device.Model,
			&device.CreatedAt,
			&device.UpdatedAt,
		); err != nil {
			return nil, fmt.Errorf("scan Home Assistant device: %w", err)
		}
		device.Enabled = true
		result = append(result, device)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate Home Assistant devices: %w", err)
	}
	return result, nil
}

func nullableText(value string) any {
	if value == "" {
		return nil
	}
	return value
}
