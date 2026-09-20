package hapostgres

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/momobox/backend/internal/homeassistant"
)

type PermissionRepository struct {
	db DB
}

func NewPermissionRepository(db DB) *PermissionRepository {
	return &PermissionRepository{db: db}
}

var _ homeassistant.PermissionRepository = (*PermissionRepository)(nil)

func (r *PermissionRepository) Get(ctx context.Context, familyID, integrationID, entityID string, role homeassistant.Role) (homeassistant.EntityPermission, error) {
	if err := requireDB(r.db); err != nil {
		return homeassistant.EntityPermission{}, err
	}
	permission, err := scanPermission(r.db.QueryRowContext(ctx, permissionSelect+`
WHERE p.family_id = $1
  AND e.integration_id = $2
  AND e.entity_id = $3
  AND p.role = $4
  AND p.deleted_at IS NULL
  AND e.deleted_at IS NULL`, familyID, integrationID, entityID, string(role)))
	if errors.Is(err, sql.ErrNoRows) {
		return homeassistant.EntityPermission{}, notFound("Home Assistant entity permission", err)
	}
	if err != nil {
		return homeassistant.EntityPermission{}, fmt.Errorf("get Home Assistant entity permission: %w", err)
	}
	return permission, nil
}

func (r *PermissionRepository) List(ctx context.Context, familyID string) ([]homeassistant.EntityPermission, error) {
	if err := requireDB(r.db); err != nil {
		return nil, err
	}
	rows, err := r.db.QueryContext(ctx, permissionSelect+`
WHERE p.family_id = $1
  AND p.deleted_at IS NULL
  AND e.deleted_at IS NULL
ORDER BY e.integration_id, e.entity_id, p.role`, familyID)
	if err != nil {
		return nil, fmt.Errorf("list Home Assistant entity permissions: %w", err)
	}
	defer rows.Close()

	result := make([]homeassistant.EntityPermission, 0)
	for rows.Next() {
		permission, scanErr := scanPermission(rows)
		if scanErr != nil {
			return nil, fmt.Errorf("scan Home Assistant entity permission: %w", scanErr)
		}
		result = append(result, permission)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate Home Assistant entity permissions: %w", err)
	}
	return result, nil
}

func (r *PermissionRepository) Upsert(ctx context.Context, permission homeassistant.EntityPermission) error {
	if err := requireDB(r.db); err != nil {
		return err
	}
	commands := make([]string, 0, len(permission.AllowedCommands))
	for _, command := range permission.AllowedCommands {
		if !homeassistant.IsAllowedCommand(command) {
			return fmt.Errorf("refuse non-whitelisted Home Assistant command %q", command)
		}
		commands = append(commands, string(command))
	}
	commandsJSON, err := marshalJSON(commands)
	if err != nil {
		return err
	}
	result, err := r.db.ExecContext(ctx, `
INSERT INTO ha_entity_permissions (
    family_id, entity_id, role, can_view, can_control, allowed_commands,
    created_at, updated_at, deleted_at
)
SELECT $1, e.id, $4, $5, $6,
       ARRAY(SELECT jsonb_array_elements_text($7::jsonb)),
       CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, NULL
FROM ha_entities AS e
WHERE e.family_id = $1
  AND e.integration_id = $2
  AND e.entity_id = $3
  AND e.deleted_at IS NULL
ON CONFLICT (entity_id, role)
DO UPDATE SET
    family_id = EXCLUDED.family_id,
    can_view = EXCLUDED.can_view,
    can_control = EXCLUDED.can_control,
    allowed_commands = EXCLUDED.allowed_commands,
    updated_at = CURRENT_TIMESTAMP,
    deleted_at = NULL`,
		permission.FamilyID,
		permission.IntegrationID,
		permission.EntityID,
		string(permission.Role),
		permission.CanView,
		permission.CanControl,
		commandsJSON,
	)
	if err != nil {
		return fmt.Errorf("upsert Home Assistant entity permission: %w", err)
	}
	return requireAffected(result, "Home Assistant entity")
}

const permissionSelect = `
SELECT p.family_id::text, e.integration_id::text, e.entity_id, p.role,
       p.can_view, p.can_control, to_json(p.allowed_commands)
FROM ha_entity_permissions AS p
JOIN ha_entities AS e
  ON e.id = p.entity_id AND e.family_id = p.family_id
`

func scanPermission(row scanner) (homeassistant.EntityPermission, error) {
	var permission homeassistant.EntityPermission
	var role string
	var commandsJSON []byte
	err := row.Scan(
		&permission.FamilyID,
		&permission.IntegrationID,
		&permission.EntityID,
		&role,
		&permission.CanView,
		&permission.CanControl,
		&commandsJSON,
	)
	if err != nil {
		return homeassistant.EntityPermission{}, err
	}
	var commands []string
	if err := json.Unmarshal(commandsJSON, &commands); err != nil {
		return homeassistant.EntityPermission{}, fmt.Errorf("decode Home Assistant allowed commands: %w", err)
	}
	permission.Role = homeassistant.Role(role)
	permission.AllowedCommands = make([]homeassistant.Command, 0, len(commands))
	for _, command := range commands {
		permission.AllowedCommands = append(permission.AllowedCommands, homeassistant.Command(command))
	}
	return permission, nil
}
