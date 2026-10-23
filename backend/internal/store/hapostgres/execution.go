package hapostgres

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/momobox/backend/internal/homeassistant"
)

// Each method autocommits on a dedicated connection. No execution ledger call
// may be enlisted in the sync transaction that is settled after the HTTP call.
type CommandExecutionRepository struct{ db DB }

func NewCommandExecutionRepository(db DB) *CommandExecutionRepository {
	return &CommandExecutionRepository{db: db}
}
func (r *CommandExecutionRepository) Begin(ctx context.Context, familyID, requestID, fingerprint string) (homeassistant.CommandExecution, bool, error) {
	if err := requireDB(r.db); err != nil {
		return homeassistant.CommandExecution{}, false, err
	}
	var inserted string
	err := r.db.QueryRowContext(ctx, `INSERT INTO ha_command_executions (family_id,request_id,fingerprint,status) VALUES ($1::uuid,$2::uuid,$3,'pending') ON CONFLICT (family_id,request_id) DO NOTHING RETURNING status`, familyID, requestID, fingerprint).Scan(&inserted)
	if err == nil {
		return homeassistant.CommandExecution{Status: inserted, Fingerprint: fingerprint}, true, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return homeassistant.CommandExecution{}, false, fmt.Errorf("reserve HA execution: %w", err)
	}
	var execution homeassistant.CommandExecution
	var payload []byte
	if err := r.db.QueryRowContext(ctx, `SELECT status,fingerprint,response_payload FROM ha_command_executions WHERE family_id=$1::uuid AND request_id=$2::uuid`, familyID, requestID).Scan(&execution.Status, &execution.Fingerprint, &payload); err != nil {
		return execution, false, fmt.Errorf("read HA execution: %w", err)
	}
	if execution.Status == "succeeded" {
		if err := json.Unmarshal(payload, &execution.Result); err != nil {
			return execution, false, fmt.Errorf("decode HA execution receipt: %w", err)
		}
	}
	return execution, false, nil
}
func (r *CommandExecutionRepository) Complete(ctx context.Context, familyID, requestID, fingerprint string, execution homeassistant.CommandExecution) error {
	if execution.Status != "succeeded" && execution.Status != "rejected" && execution.Status != "unknown" {
		return errors.New("invalid HA execution terminal status")
	}
	var payload any
	if execution.Status == "succeeded" {
		encoded, err := json.Marshal(execution.Result)
		if err != nil {
			return err
		}
		payload = encoded
	}
	result, err := r.db.ExecContext(ctx, `UPDATE ha_command_executions SET status=$4,response_payload=$5::jsonb,completed_at=CURRENT_TIMESTAMP WHERE family_id=$1::uuid AND request_id=$2::uuid AND fingerprint=$3 AND status='pending'`, familyID, requestID, fingerprint, execution.Status, payload)
	if err != nil {
		return fmt.Errorf("complete HA execution: %w", err)
	}
	return requireAffected(result, "pending HA execution")
}

var _ homeassistant.CommandExecutionRepository = (*CommandExecutionRepository)(nil)
