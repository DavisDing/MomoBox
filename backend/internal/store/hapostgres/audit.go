package hapostgres

import (
	"context"
	"fmt"

	"github.com/momobox/backend/internal/homeassistant"
)

type AuditRepository struct {
	db DB
}

func NewAuditRepository(db DB) *AuditRepository {
	return &AuditRepository{db: db}
}

var _ homeassistant.AuditRepository = (*AuditRepository)(nil)

func (r *AuditRepository) Append(ctx context.Context, log homeassistant.CommandAuditLog) error {
	if err := requireDB(r.db); err != nil {
		return err
	}
	if !homeassistant.IsAllowedCommand(log.Command) {
		return fmt.Errorf("refuse audit record for non-whitelisted Home Assistant command %q", log.Command)
	}
	parameters, err := marshalJSON(log.SafeParametersSummary)
	if err != nil {
		return err
	}
	result, err := auditResult(log.Result)
	if err != nil {
		return err
	}

	mutation, err := r.db.ExecContext(ctx, `
INSERT INTO ha_command_logs (
    family_id, integration_id, entity_id, requested_by_user_id, device_id,
    request_id, command, safe_parameters_summary, result, error_code,
    created_at
)
SELECT $1,
       i.id,
       e.id,
       $4,
       NULL,
       $5,
       $6,
       $7::jsonb,
       $8,
       NULLIF($9, ''),
       $10
FROM ha_integrations AS i
JOIN ha_entities AS e
  ON e.family_id = i.family_id
 AND e.integration_id = i.id
 AND e.entity_id = $3
 AND e.deleted_at IS NULL
WHERE i.family_id = $1
  AND i.id = $2
  AND i.deleted_at IS NULL`,
		log.FamilyID,
		log.IntegrationID,
		log.EntityID,
		log.RequestedBy,
		log.RequestID,
		string(log.Command),
		parameters,
		result,
		log.ErrorCode,
		log.CreatedAt,
	)
	if err != nil {
		return fmt.Errorf("append Home Assistant command audit: %w", err)
	}
	return requireAffected(mutation, "Home Assistant audit target")
}

func auditResult(value homeassistant.AuditResult) (string, error) {
	switch value {
	case homeassistant.AuditSucceeded:
		return "succeeded", nil
	case homeassistant.AuditFailed:
		return "failed", nil
	case homeassistant.AuditDenied:
		return "rejected", nil
	default:
		return "", fmt.Errorf("invalid Home Assistant audit result %q", value)
	}
}
