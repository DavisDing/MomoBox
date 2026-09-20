package hapostgres

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/momobox/backend/internal/homeassistant"
)

// ActorResolver returns the authenticated user ID associated with ctx. The
// optional resolver lets the future composition root preserve the exact actor
// in created_by_user_id/updated_by_user_id without changing domain interfaces.
type ActorResolver func(context.Context) (string, error)

type IntegrationRepository struct {
	db            DB
	actorResolver ActorResolver
}

func NewIntegrationRepository(db DB, actorResolver ...ActorResolver) *IntegrationRepository {
	var resolver ActorResolver
	if len(actorResolver) > 0 {
		resolver = actorResolver[0]
	}
	return &IntegrationRepository{db: db, actorResolver: resolver}
}

var _ homeassistant.IntegrationRepository = (*IntegrationRepository)(nil)

func (r *IntegrationRepository) Create(ctx context.Context, integration homeassistant.Integration) error {
	if err := requireDB(r.db); err != nil {
		return err
	}
	keyVersion, err := parseKeyVersion(integration.KeyVersion)
	if err != nil {
		return err
	}
	actorID, err := r.actorID(ctx, integration.FamilyID)
	if err != nil {
		return err
	}
	_, err = r.db.ExecContext(ctx, `
INSERT INTO ha_integrations (
    id, family_id, name, base_url, access_token_ciphertext, key_version,
    enabled, status, last_checked_at, created_by_user_id, updated_by_user_id,
    created_at, updated_at, deleted_at
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $10, $11, $12, NULL)`,
		integration.ID,
		integration.FamilyID,
		integration.Name,
		integration.BaseURL,
		integration.AccessTokenCiphertext,
		keyVersion,
		integration.Enabled,
		string(integration.Status),
		integration.LastCheckedAt,
		actorID,
		integration.CreatedAt,
		integration.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("create Home Assistant integration: %w", err)
	}
	return nil
}

func (r *IntegrationRepository) Get(ctx context.Context, familyID, integrationID string) (homeassistant.Integration, error) {
	if err := requireDB(r.db); err != nil {
		return homeassistant.Integration{}, err
	}
	integration, err := scanIntegration(r.db.QueryRowContext(ctx, integrationSelect+`
WHERE family_id = $1 AND id = $2 AND deleted_at IS NULL`, familyID, integrationID))
	if errors.Is(err, sql.ErrNoRows) {
		return homeassistant.Integration{}, notFound("Home Assistant integration", err)
	}
	if err != nil {
		return homeassistant.Integration{}, fmt.Errorf("get Home Assistant integration: %w", err)
	}
	return integration, nil
}

func (r *IntegrationRepository) List(ctx context.Context, familyID string) ([]homeassistant.Integration, error) {
	if err := requireDB(r.db); err != nil {
		return nil, err
	}
	rows, err := r.db.QueryContext(ctx, integrationSelect+`
WHERE family_id = $1 AND deleted_at IS NULL
ORDER BY lower(name), id`, familyID)
	if err != nil {
		return nil, fmt.Errorf("list Home Assistant integrations: %w", err)
	}
	defer rows.Close()

	result := make([]homeassistant.Integration, 0)
	for rows.Next() {
		integration, scanErr := scanIntegration(rows)
		if scanErr != nil {
			return nil, fmt.Errorf("scan Home Assistant integration: %w", scanErr)
		}
		result = append(result, integration)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("iterate Home Assistant integrations: %w", err)
	}
	return result, nil
}

func (r *IntegrationRepository) Update(ctx context.Context, familyID string, integration homeassistant.Integration) error {
	if err := requireDB(r.db); err != nil {
		return err
	}
	keyVersion, err := parseKeyVersion(integration.KeyVersion)
	if err != nil {
		return err
	}
	actorID, err := r.actorID(ctx, familyID)
	if err != nil {
		return err
	}
	result, err := r.db.ExecContext(ctx, `
UPDATE ha_integrations
SET name = $3,
    base_url = $4,
    access_token_ciphertext = $5,
    key_version = $6,
    enabled = $7,
    status = $8,
    last_checked_at = $9,
    updated_by_user_id = $10,
    updated_at = $11
WHERE family_id = $1 AND id = $2 AND deleted_at IS NULL`,
		familyID,
		integration.ID,
		integration.Name,
		integration.BaseURL,
		integration.AccessTokenCiphertext,
		keyVersion,
		integration.Enabled,
		string(integration.Status),
		integration.LastCheckedAt,
		actorID,
		integration.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("update Home Assistant integration: %w", err)
	}
	return requireAffected(result, "Home Assistant integration")
}

func (r *IntegrationRepository) Delete(ctx context.Context, familyID, integrationID string) error {
	if err := requireDB(r.db); err != nil {
		return err
	}
	actorID, err := r.actorID(ctx, familyID)
	if err != nil {
		return err
	}
	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin Home Assistant integration deletion: %w", err)
	}
	defer rollback(tx)

	// Soft-delete every active child in the same transaction so family-wide
	// entity listings cannot retain controls for a disabled integration.
	if _, err := tx.ExecContext(ctx, `
UPDATE ha_entity_permissions AS p
SET deleted_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
FROM ha_entities AS e
WHERE p.entity_id = e.id
  AND p.family_id = $1
  AND e.family_id = $1
  AND e.integration_id = $2
  AND p.deleted_at IS NULL`, familyID, integrationID); err != nil {
		return fmt.Errorf("delete Home Assistant integration permissions: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
UPDATE ha_entities
SET is_visible = FALSE,
    is_controllable = FALSE,
    deleted_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE family_id = $1 AND integration_id = $2 AND deleted_at IS NULL`, familyID, integrationID); err != nil {
		return fmt.Errorf("delete Home Assistant integration entities: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
UPDATE ha_devices
SET deleted_at = CURRENT_TIMESTAMP,
    updated_at = CURRENT_TIMESTAMP
WHERE family_id = $1 AND integration_id = $2 AND deleted_at IS NULL`, familyID, integrationID); err != nil {
		return fmt.Errorf("delete Home Assistant integration devices: %w", err)
	}
	result, err := tx.ExecContext(ctx, `
UPDATE ha_integrations
SET enabled = FALSE,
    status = 'disabled',
    updated_by_user_id = $3,
    updated_at = CURRENT_TIMESTAMP,
    deleted_at = CURRENT_TIMESTAMP
WHERE family_id = $1 AND id = $2 AND deleted_at IS NULL`, familyID, integrationID, actorID)
	if err != nil {
		return fmt.Errorf("delete Home Assistant integration: %w", err)
	}
	if err := requireAffected(result, "Home Assistant integration"); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit Home Assistant integration deletion: %w", err)
	}
	return nil
}

func (r *IntegrationRepository) actorID(ctx context.Context, familyID string) (string, error) {
	if r.actorResolver != nil {
		actorID, err := r.actorResolver(ctx)
		if err != nil {
			return "", fmt.Errorf("resolve Home Assistant integration actor: %w", err)
		}
		if strings.TrimSpace(actorID) == "" {
			return "", errors.New("resolve Home Assistant integration actor: empty user ID")
		}
		return actorID, nil
	}

	// The current domain repository contract does not carry the actor. Until
	// the composition root supplies ActorResolver, use the family's sole active
	// owner so the mandatory FK remains valid and never trusts client input.
	var ownerID string
	err := r.db.QueryRowContext(ctx, `
SELECT user_id::text
FROM family_members
WHERE family_id = $1 AND role = 'owner' AND deleted_at IS NULL
ORDER BY joined_at, user_id
LIMIT 1`, familyID).Scan(&ownerID)
	if errors.Is(err, sql.ErrNoRows) {
		return "", notFound("active family owner", err)
	}
	if err != nil {
		return "", fmt.Errorf("resolve active family owner: %w", err)
	}
	return ownerID, nil
}

const integrationSelect = `
SELECT id::text, family_id::text, name, base_url, access_token_ciphertext, key_version,
       enabled, status, last_checked_at, created_at, updated_at
FROM ha_integrations
`

type scanner interface {
	Scan(...any) error
}

func scanIntegration(row scanner) (homeassistant.Integration, error) {
	var integration homeassistant.Integration
	var keyVersion int64
	var status string
	err := row.Scan(
		&integration.ID,
		&integration.FamilyID,
		&integration.Name,
		&integration.BaseURL,
		&integration.AccessTokenCiphertext,
		&keyVersion,
		&integration.Enabled,
		&status,
		&integration.LastCheckedAt,
		&integration.CreatedAt,
		&integration.UpdatedAt,
	)
	if err != nil {
		return homeassistant.Integration{}, err
	}
	integration.KeyVersion = strconv.FormatInt(keyVersion, 10)
	integration.Status = homeassistant.IntegrationStatus(status)
	return integration, nil
}

func parseKeyVersion(value string) (int64, error) {
	parsed, err := strconv.ParseInt(strings.TrimSpace(value), 10, 32)
	if err != nil || parsed < 1 {
		return 0, fmt.Errorf("invalid Home Assistant token key version %q", value)
	}
	return parsed, nil
}

func requireAffected(result sql.Result, resource string) error {
	count, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("read %s mutation result: %w", resource, err)
	}
	if count == 0 {
		return notFound(resource, sql.ErrNoRows)
	}
	return nil
}
