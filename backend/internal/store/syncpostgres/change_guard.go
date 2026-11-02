package syncpostgres

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5/pgconn"
	syncdomain "github.com/momobox/backend/internal/sync"
)

func (r *transactionRepository) WithinChange(ctx context.Context, apply func() (syncdomain.StoredOutcome, error)) (syncdomain.StoredOutcome, error) {
	if _, err := r.tx.ExecContext(ctx, "SAVEPOINT sync_change"); err != nil {
		return syncdomain.StoredOutcome{}, err
	}
	operation, entity, entityID := r.operation, r.entity, r.entityID
	outcome, err := apply()
	if err != nil {
		if _, rollbackErr := r.tx.ExecContext(ctx, "ROLLBACK TO SAVEPOINT sync_change"); rollbackErr != nil {
			return syncdomain.StoredOutcome{}, rollbackErr
		}
		r.operation, r.entity, r.entityID = operation, entity, entityID
		var pgErr *pgconn.PgError
		if errors.As(err, &pgErr) {
			switch pgErr.Code {
			case "22P02", "22003", "22007", "22008", "22001", "23502", "23503", "23505", "23514":
				// Do not expose PostgreSQL messages, values, constraint names or SQL.
				err = syncdomain.NewBusinessError("VALIDATION_FAILED", "change contains invalid data or violates a data constraint", nil)
			}
		}
	}
	if _, releaseErr := r.tx.ExecContext(ctx, "RELEASE SAVEPOINT sync_change"); releaseErr != nil {
		return syncdomain.StoredOutcome{}, releaseErr
	}
	return outcome, err
}
